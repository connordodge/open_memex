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
                // WI #191: `memex serve: generated a new access token in ...`
                // is a line the server prints (quoted in the container docs),
                // not a command: no subcommand name ends in a colon.
                if sub.trim_matches('`').ends_with(':') {
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

/// Home-directory names a doc may show as an obvious placeholder.
const PLACEHOLDER_USERS: [&str; 7] = [
    "you",
    "YOU",
    "YOUR_USERNAME",
    "test",
    "tester",
    "person",
    "me",
];

/// Every absolute `/Users/<name>/` path in `doc` whose `<name>` is not a placeholder.
fn non_placeholder_home_paths(doc: &str) -> Vec<String> {
    let home = Regex::new(r"/Users/([^/\s`]+)/").unwrap();
    home.captures_iter(doc)
        .filter(|c| !PLACEHOLDER_USERS.contains(&&c[1]))
        .map(|c| c[0].to_string())
        .collect()
}

#[test]
fn home_path_scan_flags_a_real_name_and_allows_placeholders() {
    let real = format!("cd /{}/{}/memex && ls", "Users", "alice");
    assert_eq!(
        non_placeholder_home_paths(&real),
        vec![format!("/{}/{}/", "Users", "alice")]
    );
    for name in PLACEHOLDER_USERS {
        let doc = format!("export VAULT=/{}/{}/scratch-vault", "Users", name);
        assert!(
            non_placeholder_home_paths(&doc).is_empty(),
            "placeholder `{name}` is allowed"
        );
    }
    assert!(non_placeholder_home_paths("no paths here, only ~/memex").is_empty());
}

#[test]
fn daily_acceptance_script_runs_against_a_scratch_vault_never_the_real_one() {
    let doc = daily_acceptance();
    assert_eq!(
        non_placeholder_home_paths(&doc),
        Vec::<String>::new(),
        "the script never names a real home path or vault"
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
    // Whole-word match: `Synology Cloud Syncing` must still be flagged.
    let product = Regex::new(&format!(r"\b{}\b", regex::escape(SYNC_PRODUCT_NAME))).unwrap();
    let line = product.replace_all(line, "");
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
        "Synology Cloud Syncing a folder.",
        "Synology Cloud Syncs a folder.",
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

// ---------- AC 10: the only container definitions (Spec #189, WI #190 AC 23) ----------
//
// Hosted-vault Spec AC 10 (its ledger L3) said no container definition ships;
// Spec #189 reverses that. The tree's container definitions are exactly
// `Dockerfile` at the repo root and, once it lands, `deploy/compose.yaml`.

#[test]
fn repository_container_definitions_are_the_root_dockerfile_and_deploy_compose_only() {
    let doc = hosted_vault_doc();
    assert!(
        doc.to_lowercase().contains("docker"),
        "{HOSTED_DOC} describes the Docker route for a NAS in text"
    );
    let root = repo_root();
    assert!(
        root.join("Dockerfile").is_file(),
        "the image is defined by Dockerfile at the repo root"
    );
    let mut files = Vec::new();
    wi104_walk(&root, &mut files);
    assert!(files.len() > 50, "the walk reaches the repository's files");
    // /worktrees/ is gitignored: orchestration checkouts of other branches.
    let worktrees = root.join("worktrees");
    let offenders: Vec<String> = files
        .iter()
        .filter(|p| !p.starts_with(&worktrees))
        .filter(|p| {
            let name = p.file_name().unwrap().to_string_lossy().to_lowercase();
            name.starts_with("dockerfile")
                || name.ends_with(".dockerfile")
                || name.starts_with("containerfile")
                || name.starts_with("docker-compose")
                || name.starts_with("compose.")
        })
        .map(|p| p.strip_prefix(&root).unwrap().display().to_string())
        .filter(|rel| rel != "Dockerfile" && rel != "deploy/compose.yaml")
        .collect();
    assert!(
        offenders.is_empty(),
        "the only container definitions are Dockerfile and deploy/compose.yaml: {offenders:?}"
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
    // Match only a whole line: unbuffered stderr can land in several writes, and a
    // read between them sees a cut-off address such as `127.0.0.1:`.
    let listening = Regex::new(r"vault server listening on http://(\S+)\r?\n").unwrap();
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
    // `update_vault_guide` rewrites the Vault Guide. WI #17 (Spec #7): it is no longer "the one
    // note the agent may rewrite", because `edit_note` edits other notes' text.
    assert!(
        line.contains("Vault Guide") && line.contains("`update_vault_guide`"),
        "the invariant names the Vault Guide and `update_vault_guide`: {line}"
    );
    assert!(
        line.contains("rewrit"),
        "the invariant says `update_vault_guide` rewrites the Vault Guide: {line}"
    );
    assert!(
        line.contains("`edit_note`"),
        "the invariant names `edit_note`, the tool that edits other notes' text: {line}"
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
fn review_guide_agent_limits_say_update_vault_guide_rewrites_the_vault_guide() {
    // WI #17 (Spec #7): the Guide is no longer "the one note the agent may rewrite", because
    // `edit_note` edits other notes' text; `update_vault_guide` is still how the agent rewrites
    // the Guide. The `edit_note` item may name `update_vault_guide` too, so this finds a line
    // rather than counting them.
    let doc = daily_review();
    let section = wi243_section(&doc, "### What the agent can and cannot do");
    let lines = wi243_lines_with(&section, "`update_vault_guide`");
    assert!(
        lines.iter().any(|l| {
            l.contains("Vault Guide") && Regex::new(r"(?i)\brewrit\w*\b").unwrap().is_match(l)
        }),
        "a statement in 'What the agent can and cannot do' says `update_vault_guide` rewrites the \
         Vault Guide:\n{section}"
    );
    assert!(
        !section.contains("the one note the agent may rewrite"),
        "the old rule is gone:\n{section}"
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

// ======================================================================
// WI #377 (Spec #367, req 12, 29-33): the install docs, the release runbook,
// the v0.2.0 notes, the version bump and the glossary.
//
// Helpers carry a `wi377_` prefix so sibling WIs editing this file do not
// collide. The prose is read by hand; these tests pin the facts and the
// verbatim lines the WI names, plus the real names the docs must agree with
// (secrets in release.yml, flags in the scripts, paths in the repo).
// ======================================================================

const WI377_BUNDLED_MEMEX: &str = "/Applications/Open Memex.app/Contents/MacOS/memex";
const WI377_RELEASES_URL: &str = "https://github.com/connordodge/open_memex/releases";
const WI377_DOC_TRIO: [&str; 3] = [
    "docs/claude-desktop-setup.md",
    "docs/daily-review.md",
    "docs/hosted-vault.md",
];

/// Lower-cased, whitespace-collapsed text with every backtick removed, so a
/// needle matches however a doc wraps a name in code.
fn wi377_flat(text: &str) -> String {
    hosted_flat_lower(&text.replace('`', ""))
}

/// Whether `needles` occur in `flat` in the given order.
fn wi377_in_order(flat: &str, needles: &[&str]) -> bool {
    let mut from = 0;
    for needle in needles {
        let needle = needle.to_lowercase();
        match flat[from..].find(&needle) {
            Some(i) => from += i + needle.len(),
            None => return false,
        }
    }
    true
}

/// The items of the numbered lists in a section body: a line starting
/// `<n>. ` opens an item and everything up to the next such line belongs to it.
fn wi377_numbered_items(body: &str) -> Vec<String> {
    let start = Regex::new(r"^\d+\. ").unwrap();
    let mut items: Vec<String> = Vec::new();
    let mut in_fence = false;
    for line in body.lines() {
        if line.trim_start().starts_with("```") {
            in_fence = !in_fence;
        }
        if !in_fence && start.is_match(line) {
            items.push(line.to_string());
        } else if let Some(last) = items.last_mut() {
            last.push('\n');
            last.push_str(line);
        }
    }
    items
}

/// Each step (name, needles) is found in an item at or after the item of the
/// step before it (`distinct`: strictly after), so the steps run in order.
fn wi377_assert_steps_in_order(
    what: &str,
    items: &[String],
    steps: &[(&str, &[&str])],
    distinct: bool,
) {
    assert!(
        !items.is_empty(),
        "{what} has a numbered list (lines starting `1. `, `2. `, ...)"
    );
    let mut from = 0;
    for (name, needles) in steps {
        let found = items.iter().enumerate().skip(from).find(|(_, item)| {
            let flat = wi377_flat(item);
            needles.iter().all(|n| flat.contains(&n.to_lowercase()))
        });
        match found {
            Some((i, _)) => from = if distinct { i + 1 } else { i },
            None => panic!(
                "{what}: no numbered item from #{} on covers the step `{name}` \
                 (it must mention every one of {needles:?}); items:\n{}",
                from + 1,
                items.join("\n---\n")
            ),
        }
    }
}

fn wi377_install_section() -> HostedSection {
    hosted_section(&readme(), "the README Install section", r"^install\s*$")
}

/// Runs a repo script from the repo root with a scratch `HOME` and no
/// `LEAK_PATTERNS`; returns `(exit code, stdout, stderr)`.
fn wi377_run_script(
    rel: &str,
    args: &[&str],
    stdin: Option<&str>,
) -> (Option<i32>, String, String) {
    let home = std::env::temp_dir().join("wi377-fixture-home");
    std::fs::create_dir_all(&home).unwrap();
    let mut child = Command::new(repo_root().join(rel))
        .args(args)
        .current_dir(repo_root())
        .env("HOME", &home)
        .env_remove("LEAK_PATTERNS")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap_or_else(|e| panic!("{rel} runs: {e}"));
    let mut pipe = child.stdin.take().unwrap();
    if let Some(text) = stdin {
        pipe.write_all(text.as_bytes()).unwrap();
    }
    drop(pipe);
    let out = child.wait_with_output().unwrap();
    (
        out.status.code(),
        String::from_utf8_lossy(&out.stdout).to_string(),
        String::from_utf8_lossy(&out.stderr).to_string(),
    )
}

// ---------- README: status line ----------

#[test]
fn readme_status_line_says_public_preview_and_drops_prototype() {
    let readme = readme();
    assert!(
        readme
            .lines()
            .any(|l| l == "**Status: public preview.** Expect rough edges, and back up your vault."),
        "README.md has the exact public preview status line"
    );
    assert!(
        !readme.contains("**Status: prototype.**"),
        "README.md no longer says the status is prototype"
    );
}

// ---------- README: the Install section ----------

#[test]
fn readme_install_section_sits_near_the_top_and_links_the_releases_page_not_latest() {
    let readme = readme();
    let install = wi377_install_section();
    assert_eq!(install.level, 2, "Install is a `##` section");
    let install_at = readme.find("\n## Install").expect("## Install heading");
    let works_at = readme
        .find("\n## What works today")
        .expect("What works today");
    assert!(
        install_at < works_at,
        "## Install comes before `What works today` (near the top)"
    );
    assert!(
        install.body.contains(WI377_RELEASES_URL),
        "Install links {WI377_RELEASES_URL}:\n{}",
        install.body
    );
    assert!(
        !install.body.contains("/releases/latest"),
        "Install links the Releases page, never /releases/latest"
    );
    let flat = wi377_flat(&install.body);
    for needle in ["dmg", "drag", "applications"] {
        assert!(
            flat.contains(needle),
            "Install says to download the DMG and drag the app to Applications (`{needle}`)"
        );
    }
}

#[test]
fn readme_install_section_states_the_requirements_and_the_first_launch() {
    let install = wi377_install_section();
    assert!(
        install
            .body
            .contains("Apple silicon Mac, macOS 14 or later"),
        "Install states `Apple silicon Mac, macOS 14 or later`:\n{}",
        install.body
    );
    // The first launch step must name the buttons the vault picker really
    // has (the WI text said "Create new vault…", which no button carries).
    let picker = read_repo_file("app/lib/src/widgets/picker/vault_picker_body.dart");
    let first_launch = install
        .body
        .lines()
        .find(|l| wi377_flat(l).contains("first launch"))
        .unwrap_or_else(|| panic!("Install has a first launch step:\n{}", install.body));
    for label in ["create local vault…", "open local vault…"] {
        assert!(
            picker.contains(&format!("label: '{label}'")),
            "the vault picker has a button labelled `{label}`"
        );
        assert!(
            first_launch.contains(&format!("\"{label}\"")),
            "Install's first launch step names the real button \"{label}\": {first_launch}"
        );
    }
    for stale in ["Create new vault…", "Open existing vault…"] {
        assert!(
            !readme().contains(stale),
            "README.md names no button the picker lacks (`{stale}`)"
        );
    }
}

#[test]
fn readme_install_section_names_the_bundled_memex_path_and_the_ln_s_command() {
    let install = wi377_install_section();
    assert!(
        install.body.contains("Bundled memex"),
        "Install uses the GLOSSARY term `Bundled memex`"
    );
    assert!(
        install.body.contains(WI377_BUNDLED_MEMEX),
        "Install names the Bundled memex path {WI377_BUNDLED_MEMEX}"
    );
    let ln = format!("sudo ln -s \"{WI377_BUNDLED_MEMEX}\" /usr/local/bin/memex");
    assert!(
        install.body.contains(&ln),
        "Install shows the terminal setup `{ln}`:\n{}",
        install.body
    );
}

#[test]
fn readme_install_section_explains_the_upgrade_steps_and_watching_releases() {
    let install = wi377_install_section();
    let flat = wi377_flat(&install.body);
    for needle in [
        "download the new dmg",
        "replace the app",
        "upgrade notes",
        "back up",
    ] {
        assert!(
            flat.contains(needle),
            "Install's upgrade steps say `{needle}`:\n{}",
            install.body
        );
    }
    let watch = Regex::new(r"watch\W+custom\W+releases").unwrap();
    assert!(
        watch.is_match(&flat),
        "Install says how to get notified: Watch → Custom → Releases:\n{}",
        install.body
    );
}

#[test]
fn readme_install_section_states_the_privacy_line_and_links_license_contributing_and_security() {
    let install = wi377_install_section();
    let flat = wi377_flat(&install.body);
    // WI #40: the old "no network request" sentence is gone; the new Privacy
    // text is pinned by `readme_privacy_*` below.
    assert!(
        install.body.contains("`memex --with-embeddings`")
            && flat.contains("downloads its embedding model once"),
        "Install says `memex --with-embeddings` downloads its embedding model once"
    );
    for file in ["LICENSE", "CONTRIBUTING.md", "SECURITY.md"] {
        assert!(
            install.body.contains(&format!("]({file})")),
            "Install links {file} as `]({file})`"
        );
        assert!(
            repo_root().join(file).is_file(),
            "{file} exists, so the link works"
        );
    }
}

#[test]
fn readme_install_section_keeps_every_memex_command_real() {
    // The README must show at least one `memex <subcommand>` and every one
    // must be real; the Install section has to exist for the check to mean
    // anything about the new text.
    let install = wi377_install_section();
    assert!(
        install.body.contains("Open Memex"),
        "the Install section exists and is about the app"
    );
    assert_commands_are_real("README.md", &readme());
    // The new text itself: every `memex <subcommand>` it shows is real, and
    // every `--flag` it shows is a flag some `memex` command really takes.
    let top = subcommands_of(&[]);
    for (sub, _) in memex_invocations(&install.body) {
        assert!(
            top.contains(&sub),
            "the Install section shows `memex {sub}`, which is not a subcommand: {top:?}"
        );
    }
    let mut help = String::new();
    for args in std::iter::once(Vec::new()).chain(top.iter().map(|s| vec![s.as_str()])) {
        let out = Command::new(env!("CARGO_BIN_EXE_memex"))
            .args(&args)
            .arg("--help")
            .output()
            .expect("run memex --help");
        help.push_str(&String::from_utf8_lossy(&out.stdout));
    }
    let flag = Regex::new(r"--[a-z][a-z-]+").unwrap();
    let mut flags = 0;
    for snippet in code_snippets(&install.body) {
        for m in flag.find_iter(&snippet) {
            flags += 1;
            assert!(
                help.contains(m.as_str()),
                "the Install section shows `{}`, which no memex command takes",
                m.as_str()
            );
        }
    }
    assert!(
        flags >= 1,
        "the Install section shows `memex --with-embeddings`, so a flag to check"
    );
}

// ---------- README: binary lookup and Build from source ----------

#[test]
fn readme_binary_sentence_lists_the_lookup_order_and_drops_the_cargo_only_claim() {
    let readme = readme();
    assert!(
        !readme.contains("finds the `memex` binary at `~/.cargo/bin/memex` automatically"),
        "the old cargo-only sentence is gone"
    );
    let order = [
        "picked path",
        "Bundled memex",
        "~/.cargo/bin",
        "/usr/local/bin",
        "/opt/homebrew/bin",
    ];
    let line = readme
        .lines()
        .find(|l| wi377_in_order(&wi377_flat(l), &order));
    assert!(
        line.is_some(),
        "one README line gives the lookup order {order:?} (the picked path if it exists, \
         then the Bundled memex, then the three directories)"
    );
    assert!(
        wi377_flat(line.unwrap()).contains("if it exists"),
        "the picked path counts only if it exists: {}",
        line.unwrap()
    );
}

#[test]
fn readme_quick_start_is_now_build_from_source_and_keeps_the_cargo_and_flutter_steps() {
    let readme = readme();
    assert!(
        !readme.contains("## Quick start"),
        "README.md has no `## Quick start` heading"
    );
    assert!(
        !readme.contains("#quick-start"),
        "nothing links the old #quick-start anchor"
    );
    let build = hosted_section(&readme, "Build from source", r"^build from source\s*$");
    assert_eq!(build.level, 2, "Build from source is a `##` section");
    for needle in [
        "cargo install --path crates/memex-mcp --locked",
        "memex init",
        "flutter run -d macos",
        "flutter build macos",
    ] {
        assert!(
            build.body.contains(needle),
            "Build from source keeps `{needle}`:\n{}",
            build.body
        );
    }
}

// ---------- README: V5 and V6 upgrade sections ----------

#[test]
fn readme_v5_and_v6_sections_add_the_dmg_route_after_the_backup_step_and_keep_the_cargo_route() {
    let readme = readme();
    for (what, title_re) in [
        ("V5", r"upgrading to schema v5"),
        ("V6", r"upgrading to schema v6"),
    ] {
        let section = hosted_section(&readme, what, title_re).body;
        let backup_at = section
            .find("`memex backup")
            .unwrap_or_else(|| panic!("{what} runs `memex backup`:\n{section}"));
        let after_backup = wi377_flat(&section[backup_at..]);
        for needle in ["dmg", "install the new app", "includes memex"] {
            assert!(
                after_backup.contains(needle),
                "{what}: after the backup step the section says `{needle}` \
                 (the DMG route: install the new app; it includes memex):\n{section}"
            );
        }
        let cargo_at = section.find("cargo install").expect("the cargo route");
        assert!(
            backup_at < cargo_at,
            "{what}: `memex backup` still comes before the first `cargo install`"
        );
    }
}

// ---------- the three docs: client configs, shell snippets, cargo install ----------

/// Every `command` string in the ```json blocks of `md` (any nesting).
fn wi377_json_commands(md: &str) -> Vec<String> {
    fn walk(v: &Value, out: &mut Vec<String>) {
        match v {
            Value::Object(map) => {
                for (k, v) in map {
                    if k == "command" {
                        if let Some(s) = v.as_str() {
                            out.push(s.to_string());
                        }
                    }
                    walk(v, out);
                }
            }
            Value::Array(items) => items.iter().for_each(|v| walk(v, out)),
            _ => {}
        }
    }
    let mut out = Vec::new();
    for (lang, body) in hosted_fenced_blocks(md) {
        if lang != "json" {
            continue;
        }
        if let Ok(parsed) = serde_json::from_str::<Value>(&body) {
            walk(&parsed, &mut out);
        }
    }
    out
}

#[test]
fn client_configs_in_the_three_docs_run_the_bundled_memex_at_the_applications_path() {
    let help = Command::new(env!("CARGO_BIN_EXE_memex"))
        .args(["serve", "--help"])
        .output()
        .expect("memex serve --help runs");
    let help = String::from_utf8_lossy(&help.stdout).to_string();
    for rel in WI377_DOC_TRIO {
        let doc = read_repo_file(rel);
        let commands = wi377_json_commands(&doc);
        assert!(
            !commands.is_empty(),
            "{rel} shows a JSON client config with a `command`"
        );
        for command in &commands {
            assert_eq!(
                command, WI377_BUNDLED_MEMEX,
                "{rel}: every JSON client config runs the Bundled memex"
            );
        }
        for stale in ["/.cargo/bin/memex\"", "/.cargo/bin/memex serve"] {
            assert!(
                !doc.contains(stale),
                "{rel} no longer points a client at the cargo path (`{stale}`)"
            );
        }
        // The configs' serve flags are real ones.
        for (lang, body) in hosted_fenced_blocks(&doc) {
            if lang != "json" {
                continue;
            }
            let Ok(parsed) = serde_json::from_str::<Value>(&body) else {
                continue;
            };
            let servers = parsed.get("mcpServers").and_then(Value::as_object);
            for entry in servers.into_iter().flat_map(|m| m.values()) {
                let args = entry["args"].as_array().cloned().unwrap_or_default();
                assert_eq!(args.first().and_then(Value::as_str), Some("serve"));
                for flag in args.iter().filter_map(Value::as_str) {
                    if flag.starts_with("--") {
                        assert!(
                            help.contains(flag),
                            "{rel}: `memex serve --help` lists `{flag}`"
                        );
                    }
                }
            }
        }
    }
}

#[test]
fn claude_code_add_commands_run_the_quoted_bundled_memex() {
    // The path has a space, so the shell needs it quoted.
    let doc = read_repo_file("docs/daily-review.md");
    let line = doc
        .lines()
        .find(|l| l.contains("claude mcp add") && l.contains("serve --vault"))
        .expect("daily-review.md shows `claude mcp add ... serve --vault`");
    assert!(
        line.contains(&format!("-- \"{WI377_BUNDLED_MEMEX}\" serve --vault")),
        "the Claude Code command runs the quoted Bundled memex path: {line}"
    );
    for rel in WI377_DOC_TRIO {
        for line in read_repo_file(rel)
            .lines()
            .filter(|l| l.contains("claude mcp add") && l.contains("-- "))
        {
            assert!(
                line.contains(&format!("\"{WI377_BUNDLED_MEMEX}\"")),
                "{rel}: a `claude mcp add ... -- <command>` line runs the quoted Bundled memex: {line}"
            );
        }
    }
}

#[test]
fn shell_snippets_keep_bare_memex_and_each_doc_points_at_the_readme_ln_s_step() {
    for rel in WI377_DOC_TRIO {
        let doc = read_repo_file(rel);
        assert_commands_are_real(rel, &doc);
        assert!(
            doc.lines()
                .any(|l| l.contains("ln -s") && l.contains("README.md")),
            "{rel} has a line that points at the README's `ln -s` step \
             (it names `ln -s` and links README.md)"
        );
    }
}

#[test]
fn claude_desktop_setup_install_step_leads_with_the_app_and_keeps_cargo_install_from_source() {
    let doc = read_repo_file("docs/claude-desktop-setup.md");
    let install = hosted_section(&doc, "step 1", r"^1\. install").body;
    let bundled_at = install
        .find(WI377_BUNDLED_MEMEX)
        .unwrap_or_else(|| panic!("step 1 names the Bundled memex path:\n{install}"));
    let cargo_at = install
        .find("cargo install")
        .unwrap_or_else(|| panic!("step 1 keeps the cargo route:\n{install}"));
    assert!(
        bundled_at < cargo_at,
        "step 1 offers the app (Bundled memex) before `cargo install`"
    );
}

/// The paragraph that holds byte `idx` and the one before it, lower-cased.
fn wi377_paragraph_context(md: &str, idx: usize) -> String {
    let mut paras: Vec<(usize, &str)> = Vec::new();
    let mut pos = 0;
    for p in md.split("\n\n") {
        paras.push((pos, p));
        pos += p.len() + 2;
    }
    let at = paras
        .iter()
        .rposition(|(start, _)| *start <= idx)
        .expect("a paragraph holds the index");
    paras[at.saturating_sub(1)..=at]
        .iter()
        .map(|(_, p)| *p)
        .collect::<Vec<_>>()
        .join("\n\n")
        .to_lowercase()
}

#[test]
fn cargo_install_in_the_three_docs_is_framed_as_the_from_source_alternative() {
    let mut seen = 0;
    for rel in WI377_DOC_TRIO {
        let doc = read_repo_file(rel);
        for (idx, _) in doc.match_indices("cargo install") {
            seen += 1;
            let context = wi377_paragraph_context(&doc, idx);
            assert!(
                context.contains("from source"),
                "{rel}: `cargo install` at byte {idx} sits in a paragraph (or right after one) \
                 that says `from source`:\n{context}"
            );
        }
    }
    assert!(seen >= 3, "the three docs still mention `cargo install`");
}

#[test]
fn hosted_vault_doc_mentions_the_standalone_memex_zip_by_its_release_name() {
    let doc = hosted_vault_doc();
    assert!(
        doc.contains("memex-<ver>-macos-arm64.zip"),
        "hosted-vault.md mentions the standalone `memex-<ver>-macos-arm64.zip`"
    );
    let build = read_repo_file("scripts/release/build.sh");
    assert!(
        build.contains("memex-$VERSION-macos-arm64.zip"),
        "build.sh really names the zip memex-<version>-macos-arm64.zip"
    );
}

// ---------- docs/releasing.md ----------

const WI377_RELEASING: &str = "docs/releasing.md";

fn wi377_releasing() -> String {
    read_repo_file(WI377_RELEASING)
}

fn wi377_releasing_section(what: &str, title_re: &str) -> HostedSection {
    hosted_section(&wi377_releasing(), what, title_re)
}

#[test]
fn releasing_doc_cutover_steps_run_in_order_from_preconditions_to_fresh_clones() {
    let section = wi377_releasing_section("the one-time cutover", r"^one-time cutover");
    let items = wi377_numbered_items(&section.body);
    assert!(
        items.len() >= 8,
        "the cutover has at least 8 numbered steps, got {}",
        items.len()
    );
    let steps: [(&str, &[&str]); 8] = [
        ("1 preconditions", &["merged", "open", "pull", "main"]),
        (
            "2 the private deny-list",
            &[
                "~/.claude/orchestration/open_memex/leak-patterns.txt",
                "login",
                "public",
            ],
        ),
        (
            "3 rewrite-history.sh",
            &[
                "scripts/public-cutover/rewrite-history.sh",
                "--source",
                "--out",
                "--noreply",
                "--patterns",
            ],
        ),
        (
            "4 review the summary and the design exports",
            &["summary", "design/", "png", ".sketch"],
        ),
        (
            "5 rename the old repo, create the public one",
            &["gh repo rename open_memex-archive", "empty", "public"],
        ),
        ("6 push main and v0.1.0", &["push", "main", "v0.1.0"]),
        (
            "7 repository settings",
            &[
                "vulnerability reporting",
                "ruleset",
                "v*",
                "only",
                "release",
                "required reviewer",
                "secrets",
                "variable",
                "email privacy",
            ],
        ),
        (
            "8 fresh clones",
            &["fresh clone", "user.email", "noreply", "companion"],
        ),
    ];
    wi377_assert_steps_in_order("the cutover list", &items, &steps, true);
}

#[test]
fn releasing_doc_explains_the_deny_list_and_why_the_bare_login_is_not_in_it() {
    let doc = wi377_releasing();
    let flat = wi377_flat(&doc);
    assert!(
        doc.contains("~/.claude/orchestration/open_memex/leak-patterns.txt"),
        "the runbook names the private deny-list file"
    );
    for needle in ["email", "home", "path", "one per line"] {
        assert!(
            flat.contains(needle),
            "the deny-list step says what to list (`{needle}`)"
        );
    }
    assert!(
        flat.contains("bare") && flat.contains("login") && flat.contains("noreply"),
        "the runbook says the bare GitHub login is not listed: it is public in every repo \
         URL and in the noreply address"
    );
    assert!(
        flat.contains("empty") && (flat.contains("refuses") || flat.contains("exit 2")),
        "the runbook says an empty deny-list makes the scripts refuse"
    );
}

#[test]
fn releasing_doc_says_fresh_clones_only_and_never_set_url_on_an_old_clone() {
    let doc = wi377_releasing();
    let flat = wi377_flat(&doc);
    assert!(
        flat.contains("fresh clone"),
        "the runbook demands fresh clones"
    );
    let mentions: Vec<&str> = doc.lines().filter(|l| l.contains("set-url")).collect();
    assert!(
        !mentions.is_empty(),
        "the runbook names `git remote set-url` to forbid it"
    );
    for line in mentions {
        let flat = wi377_flat(line);
        assert!(
            flat.contains("never") || flat.contains("do not") || flat.contains("don't"),
            "every mention of set-url forbids it: {line}"
        );
    }
    assert!(
        flat.contains("worktree") && flat.contains("pre-rewrite"),
        "the runbook says old clones and worktrees hold pre-rewrite branches"
    );
}

#[test]
fn releasing_doc_every_release_steps_run_bump_notes_merge_tag_approve_check() {
    let section = wi377_releasing_section("every release", r"^every release");
    let items = wi377_numbered_items(&section.body);
    let steps: [(&str, &[&str]); 6] = [
        (
            "bump versions",
            &["app/pubspec.yaml", "cargo.toml", "cargo.lock"],
        ),
        ("write the notes", &["release-notes/v<ver>.md"]),
        ("merge", &["merge"]),
        ("push the tag", &["push", "v<ver>"]),
        ("approve the environment", &["approve", "environment"]),
        ("check the Release", &["check", "release"]),
    ];
    wi377_assert_steps_in_order("the every-release list", &items, &steps, false);
}

#[test]
fn releasing_doc_recovery_deletes_the_draft_and_the_tag_fixes_and_retags() {
    let section = wi377_releasing_section("recovery", r"^recovery");
    let flat = wi377_flat(&section.body);
    assert!(
        wi377_in_order(&flat, &["delete", "draft", "tag"]),
        "recovery deletes the draft and the tag: {}",
        section.body
    );
    // The numbered steps run in order: delete the Release and the tag, check
    // the tag is gone, fix the cause, and only then re-tag.
    let items = wi377_numbered_items(&section.body);
    let steps: [(&str, &[&str]); 4] = [
        (
            "delete the Release and its tag",
            &["delete", "release", "tag"],
        ),
        (
            "the tag is gone everywhere",
            &["git push origin --delete", "git tag -d"],
        ),
        ("fix the cause on main", &["fix", "main", "pr"]),
        ("re-tag", &["re-tag", "push"]),
    ];
    wi377_assert_steps_in_order("the recovery list", &items, &steps, true);
    assert!(
        section
            .body
            .contains("gh release delete v<ver> --cleanup-tag"),
        "recovery names the one-command delete"
    );
    // `--cleanup-tag` is a real `gh release delete` flag (checked when gh is
    // installed on this machine; CI images without it skip only this check).
    if let Ok(out) = Command::new("gh")
        .args(["release", "delete", "--help"])
        .output()
    {
        if out.status.success() {
            assert!(
                String::from_utf8_lossy(&out.stdout).contains("--cleanup-tag"),
                "gh release delete takes --cleanup-tag"
            );
        }
    }
}

#[test]
fn releasing_doc_names_every_secret_and_variable_the_release_workflow_reads() {
    let workflow = read_repo_file(".github/workflows/release.yml");
    let used = Regex::new(r"\b(?:secrets|vars)\.([A-Z][A-Z0-9_]+)").unwrap();
    let names: BTreeSet<String> = used
        .captures_iter(&workflow)
        .map(|c| c[1].to_string())
        .filter(|n| n != "GITHUB_TOKEN")
        .collect();
    for expected in [
        "MACOS_CERT_P12_BASE64",
        "MACOS_CERT_PASSWORD",
        "NOTARY_KEY_P8_BASE64",
        "NOTARY_KEY_ID",
        "NOTARY_ISSUER_ID",
        "LEAK_PATTERNS",
        "MACOS_SIGN_IDENTITY",
    ] {
        assert!(
            names.contains(expected),
            "release.yml reads {expected} (the runbook must list it): {names:?}"
        );
    }
    let doc = wi377_releasing();
    for name in &names {
        assert!(
            doc.contains(name.as_str()),
            "docs/releasing.md names `{name}`, which release.yml reads"
        );
    }
    assert!(
        wi377_flat(&doc).contains("environment secret"),
        "the runbook says these are environment secrets of the `release` environment"
    );
}

#[test]
fn releasing_doc_names_only_scripts_and_flags_that_exist() {
    let doc = wi377_releasing();
    let path = Regex::new(r"scripts/[A-Za-z0-9_./-]+\.sh").unwrap();
    let mut seen = BTreeSet::new();
    for m in path.find_iter(&doc) {
        seen.insert(m.as_str().to_string());
        assert!(
            repo_root().join(m.as_str()).is_file(),
            "docs/releasing.md names {}, which does not exist",
            m.as_str()
        );
    }
    assert!(
        seen.contains("scripts/public-cutover/rewrite-history.sh"),
        "the runbook runs rewrite-history.sh: {seen:?}"
    );
    let rewrite = read_repo_file("scripts/public-cutover/rewrite-history.sh");
    for flag in ["--source", "--out", "--noreply", "--patterns"] {
        assert!(rewrite.contains(flag), "rewrite-history.sh takes {flag}");
        assert!(doc.contains(flag), "the runbook passes {flag}");
    }
    assert!(
        doc.contains("leak-check.sh"),
        "the runbook names the Leak check script"
    );
    // Every `--flag` on a line that names a script is a flag that script has.
    let flag = Regex::new(r"--[a-z][a-z-]+").unwrap();
    let mut checked = BTreeSet::new();
    let code_lines: Vec<String> = code_snippets(&doc)
        .iter()
        .flat_map(|snippet| {
            snippet
                .replace("\\\n", " ")
                .lines()
                .map(str::to_string)
                .collect::<Vec<_>>()
        })
        .collect();
    for line in code_lines.iter().map(String::as_str) {
        for script in path.find_iter(line) {
            let source = read_repo_file(script.as_str());
            for f in flag.find_iter(line) {
                checked.insert((script.as_str().to_string(), f.as_str().to_string()));
                assert!(
                    source.contains(f.as_str()),
                    "the runbook passes {} to {}, which does not take it: {line}",
                    f.as_str(),
                    script.as_str()
                );
            }
        }
    }
    for expected in [
        ("scripts/leak-check.sh", "--artifact"),
        ("scripts/leak-check.sh", "--patterns"),
        ("scripts/public-cutover/rewrite-history.sh", "--noreply"),
    ] {
        assert!(
            checked.contains(&(expected.0.to_string(), expected.1.to_string())),
            "the runbook shows {} with {}: {checked:?}",
            expected.0,
            expected.1
        );
    }
    // The leak-check command the runbook gives for a `.sketch` file must work
    // as written: it needs `--patterns` (without it the script exits 2).
    let line = doc
        .lines()
        .find(|l| l.contains("--artifact"))
        .expect("the runbook gives a leak-check --artifact command");
    assert!(
        line.contains("--patterns ~/.claude/orchestration/open_memex/leak-patterns.txt"),
        "the --artifact command carries --patterns: {line}"
    );
}

#[test]
fn releasing_doc_design_review_commands_work_on_a_bare_mirror_and_the_scan_is_no_substitute() {
    let doc = wi377_releasing();
    let section = wi377_releasing_section("the one-time cutover", r"^one-time cutover");
    let items = wi377_numbered_items(&section.body);
    let step4 = items
        .iter()
        .find(|i| i.starts_with("4. "))
        .expect("cutover step 4");
    let flat = wi377_flat(step4);
    // The scan is not offered as a substitute for looking.
    assert!(
        !flat.contains("or scan them"),
        "step 4 never offers a scan instead of opening the exports: {step4}"
    );
    for needle in [
        "open every png",
        "yourself",
        "never replaces looking",
        "deny-list",
        "its own path",
        "stop and do not push",
    ] {
        assert!(
            flat.contains(needle),
            "step 4 says `{needle}` about the design exports:\n{step4}"
        );
    }
    // The two commands step 4 gives must work on a bare mirror like the one
    // rewrite-history.sh writes: build one with a design/ folder in it.
    let tmp = tempfile::tempdir().unwrap();
    let work = tmp.path().join("work");
    let bare = tmp.path().join("mirror.git");
    let scratch = tmp.path().join("scratch");
    std::fs::create_dir_all(work.join("design")).unwrap();
    std::fs::create_dir_all(&scratch).unwrap();
    std::fs::write(work.join("design/board.png"), b"png-bytes").unwrap();
    std::fs::write(work.join("design/kit.sketch"), b"sketch-bytes").unwrap();
    let git = |dir: &std::path::Path, args: &[&str]| {
        let out = Command::new("git")
            .current_dir(dir)
            .args([
                "-c",
                "user.name=Fixture",
                "-c",
                "user.email=fixture@example.com",
            ])
            .args([
                "-c",
                "commit.gpgsign=false",
                "-c",
                "init.defaultBranch=main",
            ])
            .args(args)
            .output()
            .expect("run git");
        assert!(
            out.status.success(),
            "git {args:?} failed: {}",
            String::from_utf8_lossy(&out.stderr)
        );
        String::from_utf8_lossy(&out.stdout).to_string()
    };
    git(&work, &["init", "-q"]);
    git(&work, &["add", "-A"]);
    git(&work, &["commit", "-q", "-m", "fixture"]);
    git(
        tmp.path(),
        &[
            "clone",
            "-q",
            "--bare",
            work.to_str().unwrap(),
            bare.to_str().unwrap(),
        ],
    );
    let code = Regex::new(r"`(git --git-dir <out> [^`]+)`").unwrap();
    let commands: Vec<String> = code
        .captures_iter(step4)
        .map(|c| c[1].to_string())
        .collect();
    assert_eq!(
        commands.len(),
        2,
        "step 4 gives a list command and an extract command: {commands:?}\n{step4}"
    );
    assert!(
        doc.contains("<scratch-dir>") && doc.contains("<out>"),
        "the placeholders are shown"
    );
    let run = |cmd: &str| {
        let cmd = cmd
            .replace("<out>", bare.to_str().unwrap())
            .replace("<scratch-dir>", scratch.to_str().unwrap());
        let out = Command::new("sh")
            .current_dir(tmp.path())
            .args(["-c", &cmd])
            .output()
            .expect("run sh");
        assert!(
            out.status.success(),
            "step 4 command `{cmd}` fails on a bare mirror: {}",
            String::from_utf8_lossy(&out.stderr)
        );
        String::from_utf8_lossy(&out.stdout).to_string()
    };
    let listed = run(&commands[0]);
    assert!(
        listed.contains("design/board.png") && listed.contains("design/kit.sketch"),
        "the ls-tree command lists the design files: {listed}"
    );
    run(&commands[1]);
    assert_eq!(
        std::fs::read(scratch.join("design/board.png")).unwrap(),
        b"png-bytes",
        "the archive command extracts the design files into the scratch folder"
    );
    assert!(scratch.join("design/kit.sketch").is_file());
}

#[test]
fn releasing_doc_checksum_step_ignores_the_assets_that_were_not_downloaded() {
    let section = wi377_releasing_section("every release", r"^every release");
    let items = wi377_numbered_items(&section.body);
    let check = items
        .iter()
        .find(|i| i.starts_with("6. "))
        .expect("every-release step 6, the Release check");
    assert!(
        check.contains("shasum -a 256 -c --ignore-missing SHA256SUMS.txt"),
        "the DMG-only checksum check passes on a good Release: {check}"
    );
    // The reason holds: with only some assets downloaded, `-c` alone fails
    // and `--ignore-missing` passes. Run both on a fixture sums file that
    // lists a file that is not there.
    let tmp = tempfile::tempdir().unwrap();
    std::fs::write(tmp.path().join("a.dmg"), b"dmg").unwrap();
    std::fs::write(tmp.path().join("b.zip"), b"zip").unwrap();
    let sums = Command::new("shasum")
        .current_dir(tmp.path())
        .args(["-a", "256", "a.dmg", "b.zip"])
        .output()
        .expect("run shasum");
    std::fs::write(tmp.path().join("SHA256SUMS.txt"), &sums.stdout).unwrap();
    std::fs::remove_file(tmp.path().join("b.zip")).unwrap();
    let strict = Command::new("shasum")
        .current_dir(tmp.path())
        .args(["-a", "256", "-c", "SHA256SUMS.txt"])
        .output()
        .unwrap();
    assert!(!strict.status.success(), "plain -c fails on a missing file");
    let relaxed = Command::new("shasum")
        .current_dir(tmp.path())
        .args(["-a", "256", "-c", "--ignore-missing", "SHA256SUMS.txt"])
        .output()
        .unwrap();
    assert!(
        relaxed.status.success(),
        "--ignore-missing passes with only the DMG: {}",
        String::from_utf8_lossy(&relaxed.stderr)
    );
}

#[test]
fn releasing_doc_has_no_real_username_home_path_or_personal_email() {
    let doc = wi377_releasing();
    assert!(
        non_placeholder_home_paths(&doc).is_empty(),
        "docs/releasing.md has a /Users/<name>/ path: {:?}",
        non_placeholder_home_paths(&doc)
    );
    let email = Regex::new(r"([A-Za-z0-9._%+-]+)@([A-Za-z0-9.-]+\.[A-Za-z]{2,})").unwrap();
    for c in email.captures_iter(&doc) {
        let (local, domain) = (&c[1], c[2].to_lowercase());
        let placeholder = domain.starts_with("example.")
            || domain.ends_with(".invalid")
            || local.contains("YOUR_USERNAME")
            || local.contains("login");
        assert!(
            placeholder,
            "docs/releasing.md shows an email that is not a placeholder: {}",
            &c[0]
        );
    }
}

// ---------- the Leak check over every doc this WI writes ----------

#[test]
fn leak_check_text_mode_passes_every_doc_this_wi_writes_and_flags_a_planted_home_path() {
    // Positive control first: the script really flags a home path (built at
    // run time so this file holds no literal one).
    let planted = format!("see /{}/{}/notes\n", "Users", "stranger");
    let (code, stdout, _) = wi377_run_script(
        "scripts/leak-check.sh",
        &["--allow-empty-patterns", "--text", "-"],
        Some(&planted),
    );
    assert_eq!(code, Some(1), "a planted home path is a leak: {stdout}");
    assert!(
        stdout
            .lines()
            .any(|l| l.starts_with("LEAK ") && !l.starts_with("LEAK WARN")),
        "the leak is reported on a LEAK line: {stdout}"
    );
    for rel in [
        "README.md",
        "docs/claude-desktop-setup.md",
        "docs/daily-review.md",
        "docs/hosted-vault.md",
        "docs/releasing.md",
        "release-notes/v0.2.0.md",
        "release-notes/README.md",
        "GLOSSARY.md",
    ] {
        let abs = repo_root().join(rel);
        let (code, stdout, stderr) = wi377_run_script(
            "scripts/leak-check.sh",
            &["--allow-empty-patterns", "--text", abs.to_str().unwrap()],
            None,
        );
        assert_eq!(
            code,
            Some(0),
            "leak-check.sh --text {rel} exits 0:\n{stdout}\n{stderr}"
        );
        assert!(
            !stdout.lines().any(|l| l.starts_with("LEAK ")),
            "no LEAK line for {rel}: {stdout}"
        );
    }
}

// ---------- release notes ----------

/// The body of the `## <title>` section, without its heading line.
fn wi377_section_text(md: &str, title: &str) -> String {
    let section = hosted_sections(md)
        .into_iter()
        .find(|s| s.level == 2 && s.title == title)
        .unwrap_or_else(|| panic!("a `## {title}` section"));
    section.body.lines().skip(1).collect::<Vec<_>>().join("\n")
}

#[test]
fn release_notes_v0_2_0_has_the_three_sections_with_the_exact_upgrade_and_requirements_lines() {
    let notes = read_repo_file("release-notes/v0.2.0.md");
    let titles: Vec<String> = hosted_sections(&notes)
        .into_iter()
        .filter(|s| s.level == 2)
        .map(|s| s.title)
        .collect();
    assert_eq!(
        titles,
        ["Highlights", "Upgrade", "Requirements"],
        "the notes have exactly these `##` sections, in this order"
    );
    assert_eq!(
        wi377_section_text(&notes, "Upgrade").trim(),
        "No vault changes. Vaults made by earlier builds at schema V6 open as they are."
    );
    assert_eq!(
        wi377_section_text(&notes, "Requirements").trim(),
        "Apple silicon Mac, macOS 14 or later."
    );
    let highlights = wi377_flat(&wi377_section_text(&notes, "Highlights"));
    for needle in [
        "first public release",
        "bundled memex",
        "mcp server",
        "readme",
        "signed and notarized",
        "dmg",
        "memex zip",
        "sha256sums.txt",
        "mit licence",
        "fonts are bundled",
        "never fetches fonts at runtime",
        "what's new since v0.1.0",
        ".memex.zip",
        "back up now",
        "memex restore",
        "moves its folder to the trash",
        "its backups are kept",
        "closes it first",
        "\"manage\" button in the vaults header",
        "opens the vault picker over your open vault",
        "folder icon for a local vault",
        "server icon for a hosted one",
        "show in finder",
        "remove from recents",
        "work from the keyboard",
    ] {
        assert!(
            highlights.contains(needle),
            "Highlights says `{needle}`: {highlights}"
        );
    }
    let acceptance = read_repo_file("docs/daily-acceptance.md");
    assert!(
        acceptance.contains("open local vault") && !acceptance.contains("Open existing vault"),
        "daily-acceptance.md names the real picker button"
    );
}

#[test]
fn release_notes_readme_shows_the_three_sections_and_the_schema_line() {
    let readme = read_repo_file("release-notes/README.md");
    for heading in ["## Highlights", "## Upgrade", "## Requirements"] {
        assert!(
            readme.lines().any(|l| l.trim() == heading),
            "release-notes/README.md shows the `{heading}` section"
        );
    }
    let schema_line = "This release migrates vaults to schema V<n> the first time it opens them. \
Back up first (the vault's Backups sheet → Back up now, or memex backup); \
older versions can't open a migrated vault.";
    assert!(
        readme.contains(schema_line),
        "release-notes/README.md carries the schema template line verbatim"
    );
}

#[test]
fn check_version_script_accepts_the_v0_7_1_tag_on_this_branch() {
    let (code, stdout, stderr) =
        wi377_run_script("scripts/release/check-version.sh", &["v0.7.1"], None);
    assert_eq!(
        code,
        Some(0),
        "check-version.sh v0.7.1 passes on this branch:\n{stdout}\n{stderr}"
    );
    let (code, _, stderr) = wi377_run_script("scripts/release/check-version.sh", &["v0.7.2"], None);
    assert_eq!(
        code,
        Some(1),
        "a tag with no matching versions fails: {stderr}"
    );
}

// ---------- version 0.7.1 ----------

#[test]
fn versions_are_0_7_1_in_the_app_the_workspace_and_the_lockfile() {
    let pubspec = read_repo_file("app/pubspec.yaml");
    assert!(
        pubspec.lines().any(|l| l == "version: 0.7.1+9"),
        "app/pubspec.yaml has the top-level line `version: 0.7.1+9`"
    );
    let cargo = read_repo_file("Cargo.toml");
    let table = cargo
        .split("[workspace.package]")
        .nth(1)
        .expect("a [workspace.package] table")
        .split("\n[")
        .next()
        .unwrap()
        .to_string();
    assert!(
        table.lines().any(|l| l.trim() == "version = \"0.7.1\""),
        "[workspace.package] has version = \"0.7.1\":\n{table}"
    );
    // Cargo.lock: every package without a `source` is a workspace crate.
    let lock = read_repo_file("Cargo.lock");
    let mut workspace_crates = Vec::new();
    for block in lock.split("[[package]]").skip(1) {
        if block.lines().any(|l| l.starts_with("source = ")) {
            continue;
        }
        let field = |key: &str| {
            block
                .lines()
                .find_map(|l| l.strip_prefix(&format!("{key} = \"")))
                .map(|v| v.trim_end_matches('"').to_string())
                .unwrap_or_default()
        };
        workspace_crates.push((field("name"), field("version")));
    }
    for name in ["memex-core", "memex-mcp"] {
        assert!(
            workspace_crates.iter().any(|(n, _)| n == name),
            "Cargo.lock lists the workspace crate {name}: {workspace_crates:?}"
        );
    }
    for (name, version) in &workspace_crates {
        assert_eq!(
            version, "0.7.1",
            "Cargo.lock has {name} at 0.7.1 (regenerated, not hand-edited)"
        );
    }
}

// ---------- GLOSSARY.md ----------

#[test]
fn glossary_ends_with_the_releases_section_holding_the_five_entries_verbatim() {
    let glossary = read_repo_file("GLOSSARY.md");
    let headings: Vec<&str> = glossary.lines().filter(|l| l.starts_with("## ")).collect();
    assert_eq!(
        headings.last().copied(),
        Some("## Releases (#356)"),
        "the last `##` section of GLOSSARY.md is `## Releases (#356)`"
    );
    let body = glossary
        .split("\n## Releases (#356)\n")
        .nth(1)
        .expect("the Releases (#356) section");
    let expected = "\
**Release**:
A published version of Open Memex on the public repo's GitHub Releases: the DMG, the standalone `memex` zip, their SHA-256 sums and the release notes, all for one `v<version>` tag.
_Avoid_: staging build (a local build for Connor), download, distribution

**Bundled memex**:
The `memex` binary shipped inside `Open Memex.app` (`Contents/MacOS/memex`), always the same version as the app around it.
_Avoid_: embedded CLI, helper, sidecar

**Leak check**:
The check that fails when a file, diff or build artifact contains a home directory path, a personal email address or another private identifier that must not go public.
_Avoid_: secret scan (secrets are only one kind of leak), audit

**Self-update**:
The app's own flow that finds a newer Release, downloads and verifies it, and replaces the installed `Open Memex.app` with it once the person chooses to relaunch.
_Avoid_: auto-update, upgrade, patch

**Appcast**:
The signed feed of Releases, in Sparkle's appcast XML format, that Self-update reads to learn the newest version and where to download it.
_Avoid_: update feed, manifest, releases.json";
    assert_eq!(
        body.trim(),
        expected,
        "the section holds exactly the five entries, verbatim"
    );
    assert_eq!(
        glossary.matches("## Releases (#356)").count(),
        1,
        "the section appears once"
    );
}

#[test]
fn releasing_doc_lists_the_four_release_assets_release_yml_uploads() {
    let workflow = read_repo_file(".github/workflows/release.yml");
    let upload = workflow
        .split("gh release upload")
        .nth(1)
        .expect("release.yml uploads the assets");
    let upload = upload.split("- name:").next().unwrap();
    let asset = Regex::new(r#"dist/([A-Za-z0-9_$.\-]+)"#).unwrap();
    let assets: Vec<String> = asset
        .captures_iter(upload)
        .map(|c| c[1].replace("$version", "<ver>"))
        .collect();
    assert_eq!(
        assets.len(),
        4,
        "release.yml uploads four assets: {assets:?}"
    );
    let doc = wi377_releasing();
    for name in &assets {
        assert!(
            doc.contains(name.as_str()),
            "docs/releasing.md names the uploaded asset `{name}`"
        );
    }
    assert!(
        doc.contains("--cleanup-tag"),
        "recovery deletes the tag with gh release delete --cleanup-tag"
    );
}

// ======================================================================
// WI #17 (D): the docs for agent note edits (Spec #7, Req 39; D22, D24,
// D25, D26).
//
// `edit_note`, Agent read-only, agent-edit Restore and the 20-revision
// limit replace the old rule "no tool edits an existing note". These tests
// pin the statements that can be checked mechanically; the prose around
// them is reviewed by hand. Each fact is pinned against one sentence (or one
// list item), so the wording can vary but a fact cannot go missing or be
// split across sentences. Helpers carry a `wi17_` prefix so sibling WIs
// editing this file do not collide.
// ======================================================================

const WI17_README_HEADING: &str = "## Agent note edits";

/// The README `## Agent note edits` section: it must exist exactly once.
fn wi17_readme_section() -> String {
    let readme = readme();
    let count = readme
        .lines()
        .filter(|l| l.trim_end() == WI17_README_HEADING)
        .count();
    assert_eq!(
        count, 1,
        "README.md has exactly one `{WI17_README_HEADING}` section"
    );
    wi17_h2_section(&readme, WI17_README_HEADING)
}

/// The text from the `## ` heading line that starts with `heading` to the
/// next `## ` line.
fn wi17_h2_section(md: &str, heading: &str) -> String {
    let mut out = String::new();
    let mut inside = false;
    for line in md.lines() {
        if line.starts_with("## ") {
            if inside {
                break;
            }
            inside = line.starts_with(heading);
        }
        if inside {
            out.push_str(line);
            out.push('\n');
        }
    }
    assert!(inside, "no `## ` heading starting with {heading:?}");
    out
}

/// The sentences of a markdown text: a paragraph (wrapped lines joined) or a
/// list item is one block, and a block splits at `. `. Headings, table rows
/// and code fences are blocks of their own.
fn wi17_units(text: &str) -> Vec<String> {
    let numbered = Regex::new(r"^\d+\. ").unwrap();
    let mut blocks: Vec<String> = Vec::new();
    let mut current = String::new();
    for raw in text.lines() {
        let line = raw.trim();
        let own_block = line.starts_with('#') || line.starts_with('|') || line.starts_with("```");
        let item = line.starts_with("- ") || line.starts_with("* ") || numbered.is_match(line);
        if (line.is_empty() || own_block || item) && !current.is_empty() {
            blocks.push(std::mem::take(&mut current));
        }
        if line.is_empty() {
            continue;
        }
        let body = line
            .strip_prefix("- ")
            .or_else(|| line.strip_prefix("* "))
            .unwrap_or(line);
        if own_block {
            blocks.push(body.to_string());
            continue;
        }
        if !current.is_empty() {
            current.push(' ');
        }
        current.push_str(body);
    }
    if !current.is_empty() {
        blocks.push(current);
    }
    blocks
        .iter()
        .flat_map(|b| b.split(". "))
        .map(|s| s.trim().trim_end_matches('.').to_string())
        .filter(|s| !s.is_empty())
        .collect()
}

/// Asserts that one sentence of `text` matches every regex of `all`
/// (case-insensitive).
fn wi17_assert_sentence(what: &str, text: &str, all: &[&str]) {
    let units = wi17_units(text);
    let patterns: Vec<Regex> = all
        .iter()
        .map(|p| Regex::new(&format!("(?i){p}")).unwrap())
        .collect();
    assert!(
        units.iter().any(|u| patterns.iter().all(|r| r.is_match(u))),
        "{what}: no one sentence matches all of {all:?}; the sentences are:\n{}",
        units.join("\n")
    );
}

/// The list item (a line starting `- `, with its wrapped or indented
/// continuation lines up to the next line starting `- `) that contains
/// `needle`.
fn wi17_item_with(section: &str, needle: &str) -> String {
    let lines: Vec<&str> = section.lines().collect();
    let at = lines
        .iter()
        .position(|l| l.contains(needle))
        .unwrap_or_else(|| panic!("no line contains {needle}:\n{section}"));
    let mut start = at;
    while start > 0 && !lines[start].trim_start().starts_with("- ") {
        start -= 1;
    }
    let mut end = at + 1;
    while end < lines.len()
        && !lines[end].trim_start().starts_with("- ")
        && !lines[end].trim().is_empty()
    {
        end += 1;
    }
    lines[start..end].join(" ")
}

// ---------- README: what edit_note does (AC 1) ----------

#[test]
fn readme_agent_note_edits_section_describes_form_a_edits_and_form_b_content_md() {
    let section = wi17_readme_section();
    assert!(
        section.contains("`edit_note`"),
        "the section names `edit_note`:\n{section}"
    );
    wi17_assert_sentence(
        "Form A",
        &section,
        &[
            r"`edits`",
            r"`old_text`",
            r"exactly once",
            r"note body|body of the note|above the footer",
        ],
    );
    assert!(
        section.contains("case- and byte-exact"),
        "Form A says a match is case- and byte-exact:\n{section}"
    );
    wi17_assert_sentence("Form A all-or-nothing", &section, &[r"all-or-nothing"]);
    wi17_assert_sentence(
        "Form A's version",
        &section,
        &[r"`expected_version`", r"optional"],
    );
    wi17_assert_sentence(
        "Form B",
        &section,
        &[
            r"`content_md`",
            r"replaces the whole body",
            r"above the footer",
        ],
    );
    wi17_assert_sentence(
        "Form B's version",
        &section,
        &[r"`content_md`", r"`expected_version`", r"required"],
    );
}

#[test]
fn readme_agent_note_edits_section_says_bullets_are_one_to_three_lines_of_at_most_200_characters_shown_in_the_activity_tab(
) {
    let section = wi17_readme_section();
    wi17_assert_sentence(
        "bullets",
        &section,
        &[r"bullets", r"1 to 3", r"200 characters"],
    );
    wi17_assert_sentence(
        "bullets in the Activity tab",
        &section,
        &[r"bullets", r"Activity tab"],
    );
}

#[test]
fn readme_agent_note_edits_section_says_edit_note_changes_the_body_only_and_keeps_transclusions_and_the_footer(
) {
    let section = wi17_readme_section();
    wi17_assert_sentence(
        "body only",
        &section,
        &[
            r"`edit_note`|\bit\b",
            r"body only",
            r"never",
            r"title",
            r"frontmatter",
            r"footer",
        ],
    );
    wi17_assert_sentence(
        "transclusions kept",
        &section,
        &[r"transclusion", r"\bkeeps?\b", r"`excerpt_rule`"],
    );
    wi17_assert_sentence(
        "filing goes through the excerpt tools",
        &section,
        &[
            r"filing",
            r"`add_excerpt`",
            r"`remove_excerpt`",
            r"`remove_excerpt_block`",
        ],
    );
}

#[test]
fn readme_agent_note_edits_section_names_the_notes_edit_note_refuses_with_their_error_codes() {
    let section = wi17_readme_section();
    wi17_assert_sentence(
        "refused notes",
        &section,
        &[
            r"refuses",
            r"daily notes",
            r"`marker_rule`",
            r"Vault Guide",
            r"`guide_rule`",
            r"Agent read-only",
            r"`read_only_rule`",
        ],
    );
}

#[test]
fn readme_agent_note_edits_section_says_an_open_code_fence_is_edit_invalid_and_overlapping_matches_are_edit_ambiguous(
) {
    let section = wi17_readme_section();
    wi17_assert_sentence(
        "D25 code fence",
        &section,
        &[r"code fence", r"`edit_invalid`", r"footer"],
    );
    wi17_assert_sentence(
        "D25 overlapping matches",
        &section,
        &[
            r"overlapping",
            r"separate matches",
            r"`aa`",
            r"`aaa`",
            r"`edit_ambiguous`",
        ],
    );
}

// ---------- README: Agent read-only, Restore and revisions (AC 2) ----------

#[test]
fn readme_agent_note_edits_section_describes_agent_read_only_that_only_the_person_sets() {
    let section = wi17_readme_section();
    wi17_assert_sentence(
        "what Agent read-only is",
        &section,
        &[
            r"Agent read-only",
            r"flag",
            r"only (you|the person)",
            r"\bset",
        ],
    );
    wi17_assert_sentence(
        "where the person sets it",
        &section,
        &[r"Agent read-only", r"⋯", r"`memex read-only set", r"clear"],
    );
    wi17_assert_sentence(
        "what an agent can still do",
        &section,
        &[r"agents?", r"still", r"read", r"search", r"link"],
    );
}

#[test]
fn readme_agent_note_edits_section_says_agent_read_only_does_not_apply_to_daily_notes_or_the_vault_guide(
) {
    let section = wi17_readme_section();
    wi17_assert_sentence(
        "the Agent read-only flag does not apply to daily notes or the Vault Guide",
        &section,
        &[r"does not apply", r"daily notes", r"Vault Guide"],
    );
}

#[test]
fn readme_agent_note_edits_section_describes_revisions_restore_and_the_newest_20_kept() {
    let section = wi17_readme_section();
    wi17_assert_sentence(
        "an agent edit keeps a revision",
        &section,
        &[r"agent edit", r"revision", r"replaced"],
    );
    wi17_assert_sentence(
        "the revision limit",
        &section,
        &[r"newest 20", r"revisions?", r"per note"],
    );
    wi17_assert_sentence(
        "Restore",
        &section,
        &[
            r"Restore",
            r"Activity tab",
            r"`memex revisions restore`",
            r"new revision",
        ],
    );
    wi17_assert_sentence(
        "person saves make no revisions",
        &section,
        &[
            r"\bsaves?\b",
            r"\bno revisions?\b|never (makes?|keeps?|creates?) (a )?revisions?",
        ],
    );
}

// ---------- README: the person commands (AC 2, AC 4) ----------

#[test]
fn readme_lists_the_read_only_and_revisions_commands_with_real_flags() {
    let readme = readme();
    let read_only: Vec<&str> = readme
        .lines()
        .filter(|l| l.contains("memex read-only"))
        .collect();
    assert!(
        read_only.iter().any(|l| {
            l.contains("set")
                && l.contains("clear")
                && l.contains("--vault")
                && l.contains("--note-id")
        }),
        "a README line shows `memex read-only set|clear --vault … --note-id …`: {read_only:?}"
    );
    let revisions: Vec<&str> = readme
        .lines()
        .filter(|l| l.contains("memex revisions"))
        .collect();
    assert!(
        revisions.iter().any(|l| {
            l.contains("list")
                && l.contains("restore")
                && l.contains("--vault")
                && l.contains("--note-id")
                && l.contains("--revision-id")
        }),
        "a README line shows `memex revisions list|restore` with `--note-id` and `--revision-id`: \
         {revisions:?}"
    );
    // Both commands exist (the check also covers every other command shown).
    assert_commands_are_real("README.md", &readme);
}

/// The `--flag` names in the `--help` of `memex <args>`.
fn wi17_help_flags(args: &[&str]) -> BTreeSet<String> {
    let out = Command::new(env!("CARGO_BIN_EXE_memex"))
        .args(args)
        .arg("--help")
        .output()
        .expect("run memex --help");
    assert!(out.status.success(), "memex {args:?} --help failed");
    let text = String::from_utf8_lossy(&out.stdout).to_string();
    Regex::new(r"--[a-z][a-z-]*")
        .unwrap()
        .find_iter(&text)
        .map(|m| m.as_str().to_string())
        .collect()
}

#[test]
fn readme_person_command_flags_are_flags_the_real_subcommands_accept() {
    let readme = readme();
    let span = Regex::new(r"`memex (read-only|revisions) ([a-z|]+)([^`]*)`").unwrap();
    let flag = Regex::new(r"--[a-z][a-z-]*").unwrap();
    let mut shown: BTreeSet<(String, String, String)> = BTreeSet::new();
    for c in span.captures_iter(&readme) {
        for action in c[2].split('|') {
            let accepted = wi17_help_flags(&[&c[1], action]);
            for f in flag.find_iter(&c[3]) {
                assert!(
                    accepted.contains(f.as_str()),
                    "README shows `memex {} {action} {}`, which `memex {} {action} --help` does \
                     not list: {accepted:?}",
                    &c[1],
                    f.as_str(),
                    &c[1]
                );
                shown.insert((c[1].to_string(), action.to_string(), f.as_str().to_string()));
            }
        }
    }
    // The README shows the flags it promises for each action.
    for (group, action, f) in [
        ("read-only", "set", "--note-id"),
        ("read-only", "clear", "--note-id"),
        ("revisions", "list", "--note-id"),
        ("revisions", "restore", "--revision-id"),
    ] {
        assert!(
            shown.contains(&(group.to_string(), action.to_string(), f.to_string())),
            "README shows `memex {group} {action} {f}`: {shown:?}"
        );
    }
}

#[test]
fn docs_name_edit_note_only_as_a_tool_the_server_really_serves() {
    let (tools, _) = served_names();
    assert!(
        tools.contains("edit_note"),
        "the server serves `edit_note`: {tools:?}"
    );
    let edit_token = Regex::new(r"`(edit_[a-z_]+)`").unwrap();
    for doc in [
        "README.md",
        "docs/daily-review.md",
        "docs/tags.md",
        "docs/claude-desktop-setup.md",
        "GLOSSARY.md",
    ] {
        let text = read_repo_file(doc);
        // Every backticked `edit_…` token is a served tool, except the two error codes.
        for c in edit_token.captures_iter(&text) {
            if &c[1] == "edit_invalid" || &c[1] == "edit_ambiguous" {
                continue;
            }
            assert!(
                tools.contains(&c[1]),
                "{doc} names `{}`, which the server does not expose: {tools:?}",
                &c[1]
            );
        }
    }
    assert!(
        readme().contains("`edit_note`"),
        "the README names `edit_note`"
    );
}

#[test]
fn readme_invariant_line_says_edit_note_is_the_only_prose_editor_and_link_and_excerpt_tools_write_only_link_and_transclusion_text(
) {
    let readme = readme();
    let lines: Vec<&str> = readme
        .lines()
        .filter(|l| l.contains("`append_to_daily_note`") && l.contains("daily note body"))
        .collect();
    assert_eq!(lines.len(), 1, "one invariant line: {lines:?}");
    let line = lines[0];
    wi17_assert_sentence(
        "edit_note is the only tool that edits the text you wrote",
        line,
        &[r"`edit_note`", r"only tool", r"text you wrote"],
    );
    wi17_assert_sentence(
        "link and excerpt tools write only link and transclusion text and respect Agent read-only",
        line,
        &[
            r"`add_link`",
            r"`update_link`",
            r"`add_excerpt`",
            r"`remove_excerpt`",
            r"`remove_excerpt_block`",
            r"only link and transclusion text",
            r"Agent read-only",
        ],
    );
    assert!(
        !line.contains("only through `edit_note`"),
        "the invariant no longer claims edit_note and update_vault_guide are the only text \
         writers: {line}"
    );
}

// ---------- README: the old rule is gone (AC 3) ----------

#[test]
fn readme_no_longer_says_no_tool_edits_a_note_and_names_edit_note_on_the_invariant_and_by_design_lines(
) {
    let readme = readme();
    for stale in [
        "None of the tools renames, edits or deletes an existing note",
        "the one note the agent may rewrite",
        "the one note an agent may edit",
    ] {
        assert!(
            !readme.contains(stale),
            "README.md still states the old rule: `{stale}`"
        );
    }
    let invariant: Vec<&str> = readme
        .lines()
        .filter(|l| l.contains("`append_to_daily_note`") && l.contains("daily note body"))
        .collect();
    assert_eq!(invariant.len(), 1, "one invariant line: {invariant:?}");
    assert!(
        invariant[0].contains("`edit_note`"),
        "the invariant line says what `edit_note` may change: {}",
        invariant[0]
    );
    let by_design = wi243_lines_with(&readme, "by design agents only");
    assert_eq!(by_design.len(), 1, "one 'by design' line: {by_design:?}");
    assert!(
        by_design[0].contains("`edit_note`"),
        "the 'by design' line says agents edit note text with `edit_note`: {}",
        by_design[0]
    );
}

#[test]
fn readme_out_of_scope_list_drops_note_editing_tools_but_keeps_rename_and_delete() {
    let readme = readme();
    assert!(
        !readme.contains("MCP tools that rename, edit or delete existing notes"),
        "the out-of-scope list no longer lists note-editing MCP tools"
    );
    let deferred = wi17_h2_section(&readme, "## What's deferred");
    assert!(
        deferred.contains("MCP tools that rename or delete existing notes"),
        "renaming and deleting stay out of scope:\n{deferred}"
    );
}

// ---------- docs/daily-review.md (AC 4, AC 5) ----------

#[test]
fn review_guide_agent_limits_list_edit_note_with_its_refusals_and_kept_transclusions() {
    let doc = daily_review();
    let section = wi243_section(&doc, "### What the agent can and cannot do");
    let item = wi17_item_with(&section, "`edit_note`");
    wi17_assert_sentence(
        "edit_note refuses daily notes, the Vault Guide and Agent read-only notes",
        &item,
        &[
            r"\brefuses\b",
            r"daily notes",
            r"the Vault Guide",
            r"Agent read-only",
        ],
    );
    wi17_assert_sentence(
        "edit_note never changes the title, the frontmatter or the Note footer",
        &item,
        &[
            r"\bnever changes\b",
            r"title",
            r"frontmatter",
            r"Note footer",
        ],
    );
    wi17_assert_sentence(
        "edit_note keeps every transclusion",
        &item,
        &[r"\bkeeps every transclusion\b"],
    );
    // The other limits stay.
    assert!(
        section.contains("It cannot rename, delete or merge notes"),
        "the rename/delete/merge limit stays:\n{section}"
    );
}

#[test]
fn review_guide_who_is_calling_section_names_the_person_commands_and_the_shell_list_gains_them() {
    let doc = daily_review();
    let section = wi243_section(&doc, "## 6. Who is calling");
    for command in ["memex read-only", "memex revisions"] {
        assert!(
            section.contains(command),
            "'Who is calling' mentions `{command}`:\n{section}"
        );
    }
    wi17_assert_sentence(
        "who sets Agent read-only",
        &section,
        &[r"Agent read-only", r"\byou\b|\bperson\b"],
    );
    let list = wi243_lines_with(&doc, "do not give an agent shell access");
    assert_eq!(list.len(), 1, "one no-shell-access paragraph: {list:?}");
    for sub in ["`read-only`", "`revisions`"] {
        assert!(
            list[0].contains(sub),
            "the no-shell-access list names {sub}: {}",
            list[0]
        );
    }
}

// ---------- docs/tags.md (AC 6; D26) ----------

#[test]
fn tags_doc_says_an_agent_edit_drops_a_tag_whose_text_it_removed_except_the_system_tags() {
    let doc = read_repo_file("docs/tags.md");
    wi17_assert_sentence(
        "removals only, with the D26 exception",
        &doc,
        &[
            r"agent edit",
            r"\bdrops\b",
            r"removed",
            r"`inbox`",
            r"`agent-authored`",
            r"\bexcept\b",
        ],
    );
}

#[test]
fn tags_doc_says_an_agent_edit_never_adds_a_tag_until_your_next_save() {
    let doc = read_repo_file("docs/tags.md");
    wi17_assert_sentence(
        "an agent edit adds no tag",
        &doc,
        &[r"never adds a tag", r"next save"],
    );
}

// ---------- GLOSSARY.md (AC 7) ----------

const WI17_GLOSSARY_HEADING: &str = "## Agent note edits (#1)";
const WI17_AGENT_READ_ONLY_ENTRY: &str = "**Agent read-only**:\nA flag the person sets on one note that makes it read-only to agents: agents can still read, search and link to the note, but cannot change it. Only the person can set or clear it.\n_Avoid_: locked, protected, pinned (Pinned is the Smart Folder flag)";

#[test]
fn glossary_has_one_agent_note_edits_section_holding_the_agent_read_only_entry_verbatim() {
    let glossary = read_repo_file("GLOSSARY.md");
    assert_eq!(
        glossary
            .lines()
            .filter(|l| l.trim_end() == WI17_GLOSSARY_HEADING)
            .count(),
        1,
        "GLOSSARY.md has exactly one `{WI17_GLOSSARY_HEADING}` heading"
    );
    let section = wi17_h2_section(&glossary, WI17_GLOSSARY_HEADING);
    assert!(
        section.contains(WI17_AGENT_READ_ONLY_ENTRY),
        "the section holds the Agent read-only entry verbatim:\n{WI17_AGENT_READ_ONLY_ENTRY}\n\
         --- section was ---\n{section}"
    );
    assert_eq!(
        glossary.matches("**Agent read-only**").count(),
        1,
        "exactly one Agent read-only entry in GLOSSARY.md"
    );
    // The section sits before `## Agents sheet (#394)` (that one stays directly before
    // Navigation) and so before `## Releases (#356)` (which stays last).
    let headings: Vec<&str> = glossary.lines().filter(|l| l.starts_with("## ")).collect();
    let at = |h: &str| headings.iter().position(|x| x.trim_end() == h);
    let mine = at(WI17_GLOSSARY_HEADING).expect("the section");
    assert!(
        mine > at("## Terminology").expect("Terminology")
            && mine < at("## Agents sheet (#394)").expect("Agents sheet"),
        "the section sits after Terminology and before the Agents sheet section: {headings:?}"
    );
}

#[test]
fn glossary_topic_note_capture_and_vault_guide_entries_do_not_say_the_guide_is_the_only_note_an_agent_may_rewrite(
) {
    let glossary = read_repo_file("GLOSSARY.md");
    let entry = |term: &str| -> String {
        let head = format!("**{term}**:");
        let at = glossary
            .find(&head)
            .unwrap_or_else(|| panic!("GLOSSARY.md has the {head} entry"));
        glossary[at..]
            .split("\n\n")
            .next()
            .unwrap_or_default()
            .to_string()
    };
    let old_rule = Regex::new(
        r"(?i)\b(only|one)\b[^.\n]{0,40}\bnote\b[^.\n]{0,40}\b(agent|agents)\b[^.\n]{0,20}\b(rewrit\w*|edit\w*)\b",
    )
    .unwrap();
    for term in ["Topic note", "Capture", "Vault Guide"] {
        let text = entry(term);
        assert!(
            !old_rule.is_match(&text),
            "the {term} entry still says only one note may be rewritten by an agent: {text}"
        );
    }
    // Their definitions stay.
    assert!(entry("Capture").contains("append-only"));
    assert!(entry("Vault Guide").contains("The agent reads it before every Review and Capture."));
    assert!(entry("Topic note").contains("accumulates excerpts across days"));
}

// ---------- docs/claude-desktop-setup.md and docs/hosted-vault.md ----------

#[test]
fn setup_guide_limits_say_agents_edit_note_text_with_edit_note_and_renaming_and_deleting_stay_yours(
) {
    let doc = wi243_desktop_setup();
    assert!(
        !doc.contains("There are no MCP tools to edit, rename or delete an existing note"),
        "the setup guide no longer says no MCP tool edits a note"
    );
    let section = wi243_section(&doc, "## Notes / known limits");
    let lines = wi243_lines_with(&section, "`edit_note`");
    assert_eq!(
        lines.len(),
        1,
        "one statement in 'Notes / known limits' names `edit_note`:\n{section}"
    );
    let line = lines[0].to_lowercase();
    assert!(
        line.contains("renam") && line.contains("delet") && line.contains("yours"),
        "it says renaming and deleting are still yours: {}",
        lines[0]
    );
}

#[test]
fn hosted_vault_doc_notes_that_the_shared_token_means_agent_read_only_stops_mcp_agents_not_a_token_holder(
) {
    let doc = hosted_vault_doc();
    wi17_assert_sentence(
        "D24",
        &doc,
        &[
            r"Agent read-only",
            r"token",
            r"`/mcp`",
            r"`/api/v1`",
            r"shell",
        ],
    );
    assert!(
        doc.contains("#26"),
        "the D24 note points at the follow-up, #26"
    );
    // The note names the one supported shell agent, Claude Code, as a token holder.
    wi17_assert_sentence(
        "D24 names Claude Code as a token holder that Agent read-only does not bind",
        &doc,
        &[
            r"Agent read-only",
            r"Claude Code",
            r"shell",
            r"holds the token",
            r"does not bind",
            r"#claude-code",
        ],
    );
    // The Claude Code section carries the same warning where the token is exported.
    let section = wi243_section(&doc, "### Claude Code");
    wi17_assert_sentence(
        "the Claude Code section says Agent read-only does not bind it on a hosted vault",
        &section,
        &[
            r"Claude Code",
            r"holds the access token",
            r"Agent read-only does not bind it",
        ],
    );
}

// ---------- terms (AC 9) ----------

#[test]
fn docs_spell_agent_read_only_one_way_and_never_call_it_locked_protected_or_pinned() {
    let spelling = Regex::new(r"(?i)agent read-only").unwrap();
    let wrong_word = Regex::new(r"(?i)\b(lock\w*|protect\w*|pinned|pin)\b").unwrap();
    let mut docs_mentioning: Vec<&str> = Vec::new();
    for doc in [
        "README.md",
        "docs/daily-review.md",
        "docs/tags.md",
        "docs/hosted-vault.md",
        "docs/claude-desktop-setup.md",
        "GLOSSARY.md",
    ] {
        let text = read_repo_file(doc);
        let mut mentioned = false;
        for unit in wi17_units(&text) {
            if unit.starts_with("_Avoid_") || !spelling.is_match(&unit) {
                continue;
            }
            mentioned = true;
            for m in spelling.find_iter(&unit) {
                assert_eq!(
                    m.as_str(),
                    "Agent read-only",
                    "{doc} spells the glossary term: {unit}"
                );
            }
            assert!(
                !wrong_word.is_match(&unit),
                "{doc} calls Agent read-only locked, protected or pinned: {unit}"
            );
        }
        if mentioned {
            docs_mentioning.push(doc);
        }
    }
    for doc in [
        "README.md",
        "docs/daily-review.md",
        "docs/hosted-vault.md",
        "GLOSSARY.md",
    ] {
        assert!(
            docs_mentioning.contains(&doc),
            "{doc} names Agent read-only: {docs_mentioning:?}"
        );
    }
}

// ======================================================================
// WI #40 (C1): Self-update in the README and the manual acceptance
// checklist (Spec #31, req 27; Testing Strategy, Manual end-to-end check).
//
// The README's Upgrading and Privacy paragraphs, the new
// `docs/self-update-acceptance.md` and the one pointer line in
// `docs/releasing.md`. The prose is read by hand and the checklist is run on
// the first two Self-update Releases (MANUAL); these tests pin the facts that
// can be checked mechanically. Each README fact is pinned against one
// sentence, so the wording can vary but a fact cannot go missing or be split
// across sentences. Helpers carry a `wi40_` prefix so sibling WIs editing this
// file do not collide.
// ======================================================================

const WI40_ACCEPTANCE: &str = "docs/self-update-acceptance.md";

/// The README's `**Upgrading.**` paragraph and its steps, up to `**Privacy.**`.
fn wi40_upgrading() -> String {
    let readme = readme();
    let start = readme
        .find("**Upgrading.**")
        .expect("README.md has an `**Upgrading.**` paragraph");
    let rest = &readme[start..];
    let end = rest
        .find("**Privacy.**")
        .expect("README.md has a `**Privacy.**` paragraph after Upgrading");
    rest[..end].to_string()
}

/// The README's `**Privacy.**` paragraph, up to the next blank line.
fn wi40_privacy() -> String {
    let readme = readme();
    let start = readme
        .find("**Privacy.**")
        .expect("README.md has a `**Privacy.**` paragraph");
    let rest = &readme[start..];
    let end = rest.find("\n\n").unwrap_or(rest.len());
    rest[..end].to_string()
}

fn wi40_acceptance() -> String {
    read_repo_file(WI40_ACCEPTANCE)
}

/// Straight apostrophes and one-line spacing, so a quoted modal body matches
/// whichever apostrophe the doc was typed with.
fn wi40_norm(text: &str) -> String {
    text.replace(['\u{2019}', '\u{2018}'], "'")
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ")
}

/// Whether `quote` appears word for word inside a code span or a fenced block
/// of `md` (the way the doc quotes the modal's own copy).
fn wi40_quotes_in_code(md: &str, quote: &str) -> bool {
    let quote = wi40_norm(quote);
    code_snippets(md)
        .iter()
        .any(|snippet| wi40_norm(snippet).contains(&quote))
}

/// The numbered `## N. title` sections of the checklist, in order: `(N, body)`.
fn wi40_numbered_sections(doc: &str) -> Vec<(u32, String)> {
    let number = Regex::new(r"^(\d+)\.\s").unwrap();
    hosted_sections(doc)
        .into_iter()
        .filter(|s| s.level == 2)
        .filter_map(|s| {
            number
                .captures(&s.title)
                .map(|c| (c[1].parse().unwrap(), s.body))
        })
        .collect()
}

/// Section number `n` (1-based) of the checklist.
fn wi40_section(doc: &str, n: u32) -> String {
    let sections = wi40_numbered_sections(doc);
    sections
        .iter()
        .find(|(num, _)| *num == n)
        .map(|(_, body)| body.clone())
        .unwrap_or_else(|| {
            panic!(
                "{WI40_ACCEPTANCE} has a numbered section {n}: {:?}",
                sections.iter().map(|(num, _)| num).collect::<Vec<_>>()
            )
        })
}

fn wi40_assert_section_mentions(doc: &str, n: u32, needles: &[&str]) {
    let flat = wi40_norm(&wi40_section(doc, n)).to_lowercase();
    for needle in needles {
        assert!(
            flat.contains(&needle.to_lowercase()),
            "{WI40_ACCEPTANCE} section {n} mentions `{needle}`"
        );
    }
}

/// The `_Avoid_` terms of the Self-update and Appcast glossary entries that
/// cannot be mistaken for ordinary English, plus two spellings of
/// `auto-update`.
const WI40_AVOIDED: [&str; 6] = [
    "auto-update",
    "auto update",
    "autoupdate",
    "update feed",
    "manifest",
    "releases.json",
];

/// Prose (no code spans, no fenced blocks: the modal's own copy is quoted in
/// code and may say "update feed") must hold none of `WI40_AVOIDED`.
fn wi40_avoided_terms_in_prose(md: &str) -> Vec<&'static str> {
    let prose = prose_only(md).to_lowercase();
    WI40_AVOIDED
        .iter()
        .copied()
        .filter(|term| {
            Regex::new(&format!(r"\b{}\b", regex::escape(term)))
                .unwrap()
                .is_match(&prose)
        })
        .collect()
}

fn wi40_assert_no_avoided_terms(doc_name: &str, md: &str) {
    let glossary = read_repo_file("GLOSSARY.md");
    for (entry, first) in [
        ("**Self-update**", "auto-update"),
        ("**Appcast**", "update feed"),
    ] {
        let at = glossary
            .find(entry)
            .unwrap_or_else(|| panic!("GLOSSARY.md defines {entry}"));
        let avoid = glossary[at..]
            .lines()
            .find(|l| l.starts_with("_Avoid_"))
            .expect("the entry has an _Avoid_ line")
            .to_lowercase();
        assert!(
            avoid.contains(first),
            "{entry}'s _Avoid_ line lists `{first}`"
        );
    }
    assert_eq!(
        wi40_avoided_terms_in_prose(md),
        Vec::<&str>::new(),
        "{doc_name} uses an `_Avoid_` term of Self-update or Appcast outside quoted modal copy"
    );
}

#[test]
fn wi40_avoided_term_scan_flags_prose_and_allows_quoted_modal_copy() {
    assert_eq!(
        wi40_avoided_terms_in_prose("The auto-update checks the update feed daily."),
        vec!["auto-update", "update feed"]
    );
    assert!(wi40_avoided_terms_in_prose(
        "The offline copy reads `Open Memex couldn't reach the update feed.` verbatim."
    )
    .is_empty());
    assert!(
        wi40_avoided_terms_in_prose("```\nupdate feed\n```\nSelf-update reads the Appcast.")
            .is_empty()
    );
    assert!(wi40_quotes_in_code(
        "Reads `Open Memex couldn\u{2019}t  reach it.`",
        "Open Memex couldn't reach it."
    ));
    assert!(!wi40_quotes_in_code(
        "Reads \"Open Memex couldn't reach it.\" in prose.",
        "Open Memex couldn't reach it."
    ));
}

// ---------- AC 1: Upgrading says the app offers new Releases itself ----------

#[test]
fn readme_upgrading_says_the_app_offers_new_releases_itself_checks_daily_and_installs_on_relaunch()
{
    let upgrading = wi40_upgrading();
    wi17_assert_sentence(
        "Upgrading says that from the first Self-update Release on the app offers each new Release itself",
        &upgrading,
        &[r"first Self-update Release", r"\boffers?\b", r"new Release"],
    );
    wi17_assert_sentence(
        "Upgrading says the check runs once a day at launch and from Open Memex, Check for Updates…",
        &upgrading,
        &[
            r"once a day",
            r"\blaunch\b",
            r"Open Memex",
            r"Check for Updates…",
        ],
    );
    wi17_assert_sentence(
        "Upgrading says the update installs when the person chooses relaunch",
        &upgrading,
        &[r"\brelaunch\b", r"\binstalls?\b"],
    );
}

// ---------- AC 2: v0.4.0 and earlier install the first one by hand ----------

#[test]
fn readme_upgrading_says_v0_4_0_and_earlier_install_the_first_self_update_release_by_hand() {
    wi17_assert_sentence(
        "Upgrading says v0.4.0 and earlier install the first Self-update Release by hand",
        &wi40_upgrading(),
        &[
            r"v0\.4\.0",
            r"or earlier",
            r"first Self-update Release",
            r"by hand",
        ],
    );
}

// ---------- AC 3: the back-up and restart-MCP-clients steps stay ----------

#[test]
fn readme_upgrading_still_says_back_up_first_and_restart_mcp_clients_for_the_new_bundled_memex() {
    let upgrading = wi40_upgrading();
    wi17_assert_sentence(
        "Upgrading says to back up your vault first",
        &upgrading,
        &[r"back up", r"vault", r"first"],
    );
    wi17_assert_sentence(
        "Upgrading says to restart MCP clients so they start the new Bundled memex",
        &upgrading,
        &[r"restart", r"MCP clients", r"new Bundled memex"],
    );
    // Self-update replaces the app, and with it the Bundled memex, but a
    // client's running `memex serve` keeps its old binary (Spec req 22, 25).
    wi17_assert_sentence(
        "Upgrading says connected agents keep the old memex until they restart",
        &upgrading,
        &[r"connected agents", r"until they restart"],
    );
}

// ---------- AC 4: Privacy names the two requests, and neither sends vault data ----------

#[test]
fn readme_privacy_names_the_daily_appcast_fetch_and_the_dmg_download_and_says_neither_sends_vault_data(
) {
    let privacy = wi40_privacy();
    let flat = wi377_flat(&privacy);
    assert!(
        !flat.contains("no network request"),
        "Privacy no longer says the app makes no network request:\n{privacy}"
    );
    wi17_assert_sentence(
        "Privacy says the app fetches the Appcast from GitHub Pages (connordodge.github.io)",
        &privacy,
        &[
            r"fetch",
            r"Appcast",
            r"GitHub Pages",
            r"connordodge\.github\.io",
        ],
    );
    wi17_assert_sentence(
        "Privacy says the Appcast is fetched once a day at launch and on Check for Updates…",
        &privacy,
        &[r"once a day", r"\blaunch\b", r"Check for Updates…"],
    );
    wi17_assert_sentence(
        "Privacy says the DMG is downloaded from GitHub only when the person chooses install",
        &privacy,
        &[r"download", r"\bDMG\b", r"GitHub", r"only", r"\binstall\b"],
    );
    wi17_assert_sentence(
        "Privacy says neither request sends vault data",
        &privacy,
        &[r"\bNeither\b", r"vault data"],
    );
    // The embeddings sentence stays.
    assert!(
        privacy.contains("`memex --with-embeddings`")
            && flat.contains("downloads its embedding model once"),
        "Privacy keeps the `memex --with-embeddings` embedding model sentence:\n{privacy}"
    );
}

// ---------- AC 5: docs/self-update-acceptance.md ----------

#[test]
fn self_update_acceptance_doc_has_nine_numbered_sections_each_with_an_expected_line() {
    let doc = wi40_acceptance();
    assert!(
        doc.lines().next().is_some_and(|l| l.starts_with("# ")),
        "the checklist opens with a title"
    );
    let flat = wi40_norm(&doc).to_lowercase();
    assert!(
        flat.contains("first two self-update releases"),
        "the checklist says it runs once on each of the first two Self-update Releases"
    );
    let sections = wi40_numbered_sections(&doc);
    let numbers: Vec<u32> = sections.iter().map(|(n, _)| *n).collect();
    assert!(
        numbers.len() >= 9,
        "at least nine numbered `## N. title` sections: {numbers:?}"
    );
    let expected_run: Vec<u32> = (1..=numbers.len() as u32).collect();
    assert_eq!(numbers, expected_run, "sections are numbered 1..n in order");
    for (n, body) in &sections {
        assert!(
            body.contains("**Expected**"),
            "numbered section {n} has an **Expected** line: {}",
            body.lines().next().unwrap_or_default()
        );
    }
}

#[test]
fn self_update_acceptance_doc_sections_1_and_2_install_the_older_release_and_publish_the_newer_one()
{
    let doc = wi40_acceptance();
    wi40_assert_section_mentions(
        &doc,
        1,
        &["older", "Release", "DMG", "/Applications/Open Memex.app"],
    );
    wi40_assert_section_mentions(
        &doc,
        2,
        &["publish", "newer", "Appcast", "GitHub Pages", "10 minutes"],
    );
}

#[test]
fn self_update_acceptance_doc_section_3_confirms_every_modal_state_quoting_the_copy_verbatim() {
    let doc = wi40_acceptance();
    // Every state of Spec req 15: its title, by name.
    for title in [
        "Checking for updates",
        "Update available",
        "Downloading update",
        "Verifying update",
        "Update ready",
        "Update check failed",
        "Update failed",
        "Updates are off",
    ] {
        wi40_assert_section_mentions(&doc, 3, &[title]);
    }
    let section = wi40_section(&doc, 3);
    let flat = wi40_norm(&section).to_lowercase();
    assert!(
        flat.contains("you're up to date"),
        "section 3 names the up to date title"
    );
    // The three states the WI names: Off in a debug build, no Appcast (404)
    // and a folder the app cannot write.
    for needle in ["debug build", "404", "not writable"] {
        assert!(
            flat.contains(needle),
            "section 3 covers `{needle}`:\n{section}"
        );
    }
    // The modal's own copy is quoted verbatim, in code, so that "update feed"
    // in it is not an avoided term in prose.
    for quote in [
        "No updates have been published yet.",
        "Open Memex couldn't reach the update feed. Check your connection and try again.",
        "Open Memex can't replace itself in",
    ] {
        assert!(
            wi40_quotes_in_code(&section, quote),
            "section 3 quotes `{quote}` word for word in code:\n{section}"
        );
    }
}

#[test]
fn self_update_acceptance_doc_sections_4_to_6_cover_later_relaunch_with_unsent_hosted_text_and_a_connected_agent(
) {
    let doc = wi40_acceptance();
    wi40_assert_section_mentions(&doc, 4, &["later", "downloading", "· update ready"]);
    wi40_assert_section_mentions(&doc, 5, &["relaunch", "unsent", "hosted", "leave confirm"]);
    let five = wi40_norm(&wi40_section(&doc, 5)).to_lowercase();
    assert!(
        Regex::new(r"\b(once|one leave confirm|exactly one|a single)\b")
            .unwrap()
            .is_match(&five),
        "section 5 expects the leave confirm to show once: {five}"
    );
    wi40_assert_section_mentions(
        &doc,
        6,
        &[
            "relaunch",
            "Claude Desktop",
            "agent",
            "restart",
            "Bundled memex",
        ],
    );
    assert!(
        wi40_quotes_in_code(
            &wi40_section(&doc, 6),
            "Connected agents keep using the current memex until they restart."
        ),
        "section 6 quotes the agent line word for word in code"
    );
}

#[test]
fn self_update_acceptance_doc_sections_7_to_9_cover_the_disk_image_app_management_and_the_local_rehearsal(
) {
    let doc = wi40_acceptance();
    wi40_assert_section_mentions(&doc, 7, &["mounted", "DMG", "disk image"]);
    assert!(
        wi40_quotes_in_code(
            &wi40_section(&doc, 7),
            "Open Memex is running from a disk image or a temporary location, so it can't replace itself."
        ),
        "section 7 quotes the disk image message word for word in code"
    );
    wi40_assert_section_mentions(&doc, 8, &["macOS 15", "App Management", "Update failed"]);
    let eight = wi40_norm(&wi40_section(&doc, 8)).to_lowercase();
    assert!(
        Regex::new(r"(without|not|never|don't) grant")
            .unwrap()
            .is_match(&eight),
        "section 8 says not to grant App Management: {eight}"
    );
    wi40_assert_section_mentions(&doc, 9, &["rehearsal", "local", "Appcast", "v0.5.0", "tag"]);
    let nine = wi40_section(&doc, 9);
    assert!(
        code_snippets(&nine)
            .iter()
            .any(|s| s.contains("--dart-define=SELF_UPDATE_APPCAST_URL=")),
        "section 9 shows the `--dart-define=SELF_UPDATE_APPCAST_URL=<url>` build flag in code:\n{nine}"
    );
    let flat = wi40_norm(&nine).to_lowercase();
    assert!(
        wi377_in_order(&flat, &["before", "v0.5.0", "tag"]),
        "section 9 says to rehearse before the v0.5.0 tag: {flat}"
    );
}

/// One numbered step of checklist section 3: its title, the modal body quoted
/// in code, and the action labels it names. `n` is the step number.
struct Wi40ModalStep {
    n: u32,
    title: &'static str,
    quotes: &'static [&'static str],
    actions: &'static [&'static str],
}

const WI40_MODAL_STEPS: [Wi40ModalStep; 15] = [
    Wi40ModalStep {
        n: 1,
        title: "Checking for updates",
        quotes: &[],
        actions: &["spinner", "close"],
    },
    Wi40ModalStep {
        n: 2,
        title: "You're up to date",
        quotes: &["Open Memex <current> is the newest version."],
        actions: &["close"],
    },
    Wi40ModalStep {
        n: 3,
        title: "Update available",
        quotes: &["Version <new> is available."],
        actions: &["later", "install"],
    },
    Wi40ModalStep {
        n: 4,
        title: "Downloading update",
        quotes: &[],
        actions: &["progress bar", "percentage", "later"],
    },
    Wi40ModalStep {
        n: 5,
        title: "Verifying update",
        quotes: &["Checking the update's signature."],
        actions: &["spinner"],
    },
    Wi40ModalStep {
        n: 6,
        title: "Update ready",
        quotes: &["Version <new> is downloaded. Relaunch to apply it."],
        actions: &["later", "relaunch"],
    },
    Wi40ModalStep {
        n: 7,
        title: "Update check failed",
        quotes: &[
            "Open Memex couldn't reach the update feed. Check your connection and try again.",
        ],
        actions: &["close", "try again"],
    },
    Wi40ModalStep {
        n: 8,
        title: "Update check failed",
        quotes: &["No updates have been published yet."],
        actions: &["close", "try again"],
    },
    Wi40ModalStep {
        n: 9,
        title: "Update failed",
        quotes: &["Open Memex can't replace itself in"],
        actions: &["close", "download from GitHub"],
    },
    Wi40ModalStep {
        n: 10,
        title: "Updates are off",
        quotes: &["Updates are off in development builds."],
        actions: &["debug build"],
    },
    Wi40ModalStep {
        n: 11,
        title: "Update check failed",
        quotes: &["The update feed couldn't be read. Try again later."],
        actions: &["close", "try again"],
    },
    Wi40ModalStep {
        n: 12,
        title: "Update failed",
        quotes: &["The update isn't signed by the Open Memex release key, so it wasn't installed."],
        actions: &["close", "try again", "update ready"],
    },
    Wi40ModalStep {
        n: 13,
        title: "Update failed",
        quotes: &["The update has no signature, so it wasn't installed."],
        actions: &["close", "try again", "sparkle:edSignature"],
    },
    Wi40ModalStep {
        n: 14,
        title: "Update failed",
        quotes: &["This build can't verify updates. Download the update from GitHub instead."],
        actions: &["close", "download from GitHub", "no try again"],
    },
    Wi40ModalStep {
        n: 15,
        title: "Update failed",
        quotes: &["The download didn't finish. Check your connection and try again."],
        actions: &["close", "try again", "Downloading"],
    },
];

/// The numbered steps of section 3, each from its `N. ` line to the next step
/// or the `**Expected**` line: `(N, text)`.
fn wi40_section_3_steps(doc: &str) -> Vec<(u32, String)> {
    let start = Regex::new(r"^(\d+)\. ").unwrap();
    let mut steps: Vec<(u32, String)> = Vec::new();
    let mut open = false;
    for line in wi40_section(doc, 3).lines() {
        if line.starts_with("**Expected**") {
            open = false;
        } else if let Some(c) = start.captures(line) {
            steps.push((c[1].parse().unwrap(), line.to_string()));
            open = true;
        } else if open {
            if let Some((_, text)) = steps.last_mut() {
                text.push(' ');
                text.push_str(line);
            }
        }
    }
    steps
}

/// A Dart source with adjacent string literals joined (`'a '\n 'b'` -> `a b`,
/// quote marks between them dropped) and `\'` unescaped, so a message the
/// source wraps over several lines can be searched as one string.
fn wi40_dart_literals_joined(src: &str) -> String {
    Regex::new(r#"['"]\s*\n\s*['"]"#)
        .unwrap()
        .replace_all(src, "")
        .replace("\\'", "'")
}

/// The fixed text around `<placeholder>` tokens of a checklist quote.
fn wi40_quote_fragments(quote: &str) -> Vec<String> {
    Regex::new(r"<[^>]*>")
        .unwrap()
        .split(quote)
        .map(|f| f.trim().to_string())
        .filter(|f| !f.is_empty())
        .collect()
}

#[test]
fn self_update_acceptance_doc_section_3_has_fifteen_steps_each_pinning_its_title_quoted_body_and_actions(
) {
    let doc = wi40_acceptance();
    let steps = wi40_section_3_steps(&doc);
    assert_eq!(
        steps.iter().map(|(n, _)| *n).collect::<Vec<_>>(),
        (1..=15).collect::<Vec<u32>>(),
        "section 3 lists fifteen numbered modal states in order"
    );
    for expected in &WI40_MODAL_STEPS {
        let (_, text) = &steps[(expected.n - 1) as usize];
        assert!(
            wi40_norm(text).contains(&format!("**{}**", expected.title)),
            "step {} names its title **{}**: {text}",
            expected.n,
            expected.title
        );
        for quote in expected.quotes {
            assert!(
                wi40_quotes_in_code(text, quote),
                "step {} quotes `{quote}` word for word in code: {text}",
                expected.n
            );
        }
        let flat = wi40_norm(text).to_lowercase();
        for action in expected.actions {
            assert!(
                flat.contains(&action.to_lowercase()),
                "step {} names `{action}`: {text}",
                expected.n
            );
        }
    }
}

#[test]
fn wi40_dart_literal_join_and_quote_fragments_work_on_wrapped_messages() {
    let src = "=>\n    \"Open Memex couldn't reach the update feed. Check your connection \"\n        'and try again.',\n  x => 'a \\'b\\'';\n";
    let joined = wi40_dart_literals_joined(src);
    assert!(joined.contains(
        "Open Memex couldn't reach the update feed. Check your connection and try again."
    ));
    assert!(joined.contains("a 'b'"));
    assert!(!joined.contains("connection \"\n"));
    assert_eq!(
        wi40_quote_fragments("Version <new> is downloaded. Relaunch to apply it."),
        vec!["Version", "is downloaded. Relaunch to apply it."]
    );
    assert!(wi40_quote_fragments("<only>").is_empty());
}

#[test]
fn self_update_acceptance_doc_quotes_match_the_modal_source_once_it_has_landed() {
    let src = read_repo_file("app/lib/src/updater/update_modal.dart");
    let joined = wi40_dart_literals_joined(&src);
    // While update_modal.dart is still the A0 stub there is no copy to compare.
    if !joined.contains("Updates are off in development builds.") {
        eprintln!("update_modal.dart has no modal copy yet; nothing to compare");
        return;
    }
    let mut quotes: Vec<(String, &str)> = WI40_MODAL_STEPS
        .iter()
        .flat_map(|s| s.quotes.iter().map(move |q| (format!("step {}", s.n), *q)))
        .collect();
    quotes.push((
        "section 6".into(),
        "Connected agents keep using the current memex until they restart.",
    ));
    quotes.push((
        "section 7".into(),
        "Open Memex is running from a disk image or a temporary location, so it can't replace itself. Move Open Memex to your Applications folder, open it from there and try again.",
    ));
    for (at, quote) in &quotes {
        for fragment in wi40_quote_fragments(quote) {
            assert!(
                joined.contains(&fragment),
                "{at}: the checklist quotes `{fragment}` but update_modal.dart has no such text"
            );
        }
    }
    for step in &WI40_MODAL_STEPS {
        assert!(
            joined.contains(&format!("'{}'", step.title))
                || joined.contains(&format!("\"{}\"", step.title)),
            "step {}: update_modal.dart has no title `{}`",
            step.n,
            step.title
        );
    }
    for label in [
        "close",
        "later",
        "install",
        "relaunch",
        "try again",
        "download from GitHub",
    ] {
        assert!(
            joined.contains(&format!("'{label}'")),
            "update_modal.dart has an action labelled `{label}`"
        );
    }
}

#[test]
fn self_update_acceptance_doc_section_9_rehearses_on_a_separate_keychain_account_and_a_localhost_enclosure(
) {
    let doc = wi40_acceptance();
    let nine = wi40_section(&doc, 9);
    let flat = wi40_norm(&nine);
    // The rehearsal key lives on its own Keychain account, never the release key's.
    assert!(
        wi40_quotes_in_code(&nine, "generate_keys --account open-memex-rehearsal")
            && wi40_quotes_in_code(
                &nine,
                "generate_keys --account open-memex-rehearsal -x <scratch key file>"
            ),
        "section 9 mints and exports the key on the open-memex-rehearsal account: {nine}"
    );
    let bare =
        Regex::new(r"generate_keys\s+(?:-x\s+\S+\s+)?--account\s+open-memex(?:\s|`|$)").unwrap();
    assert!(
        !bare.is_match(&nine),
        "section 9 never runs generate_keys on the release key's own account: {nine}"
    );
    assert!(
        flat.contains("never the release key's account `open-memex`"),
        "section 9 says never to use the release key's account: {flat}"
    );
    assert!(
        flat.contains("delete only the `open-memex-rehearsal` item")
            && flat.contains("the release key's `open-memex` item must stay"),
        "section 9 deletes only the rehearsal Keychain item: {flat}"
    );
    // The generator writes a GitHub enclosure; the checklist rewrites it to localhost.
    assert!(
        flat.contains("always writes the GitHub Releases address"),
        "section 9 says the generator writes the GitHub address: {flat}"
    );
    assert!(
        wi40_quotes_in_code(&nine, "http://localhost:8000/Open-Memex-<newer>-arm64.dmg")
            && flat.contains("edit the item's enclosure `url`"),
        "section 9 rewrites the enclosure url to the local DMG: {flat}"
    );
    assert!(
        wi40_quotes_in_code(&nine, "http://localhost:8000/appcast.xml"),
        "section 9 points the build at the local Appcast"
    );
    // Prerequisites of the generator and the signer.
    for needle in [
        "release-notes/v<newer>.md",
        "sign_update",
        "`PATH`",
        "one empty channel",
        "scripts/release/generate_appcast.sh --version <newer>",
        "scripts/release/eddsa_sign.sh",
        ".edsig",
        ".length",
    ] {
        assert!(
            flat.contains(needle),
            "section 9 mentions `{needle}`: {flat}"
        );
    }
}

#[test]
fn self_update_acceptance_doc_sections_3_5_and_8_pin_run_order_and_expected_outcomes() {
    let doc = wi40_acceptance();
    // Section 3: once at Update ready, Check for Updates only reopens the
    // modal, so the failure states need a quit and reopen first.
    let three = wi40_norm(&wi40_section(&doc, 3));
    assert!(
        three.contains("only reopens that modal, so quit and reopen the app before any step that needs a fresh check (steps 7 to 15)"),
        "section 3 says to quit and reopen before steps 7 to 15: {three}"
    );
    assert!(
        three.contains("Steps 11 to 15 need the local setup of section 9."),
        "section 3 says steps 11 to 15 need the section 9 setup"
    );
    assert!(
        three.contains("Sections 5 and 6 start from this state."),
        "section 3 says sections 5 and 6 start from Update ready"
    );
    // Section 3 Expected: one modal at a time, and no stray download folder.
    let expected = wi40_norm(
        wi40_section(&doc, 3)
            .split("**Expected**")
            .nth(1)
            .expect("section 3 has an Expected line"),
    );
    for needle in [
        "never two modals at once",
        "one modal",
        "the temporary download folder for the update is gone",
    ] {
        assert!(
            expected.contains(needle),
            "section 3 Expected says `{needle}`: {expected}"
        );
    }
    // Section 5: cancel keeps Update ready; the second relaunch asks nothing.
    let five = wi40_norm(&wi40_section(&doc, 5));
    for needle in [
        "asks about the unsent text exactly one time",
        "Choosing cancel closes the modal and the update stays Update ready",
        "the label still reading `· update ready`",
        "the app quits without asking a second time",
        "the newer Release opens from `/Applications/Open Memex.app` showing `v<newer>`",
    ] {
        assert!(five.contains(needle), "section 5 says `{needle}`: {five}");
    }
    // Section 8: both outcomes, the once-only failure, and no half install.
    let eight = wi40_norm(&wi40_section(&doc, 8));
    for needle in [
        "the update installs and the newer Release opens",
        "the app relaunches on the older Release",
        "the next launch shows Update failed once, with the reason",
        "the modal's try again goes back to Checking",
        "Record which of the two happened for this macOS version",
        "never leaves a half-installed `Open Memex.app` in `/Applications`",
    ] {
        assert!(eight.contains(needle), "section 8 says `{needle}`: {eight}");
    }
}

// ---------- AC 6: docs/releasing.md points at the checklist ----------

#[test]
fn releasing_doc_links_the_self_update_acceptance_checklist_from_every_release() {
    let doc = wi377_releasing();
    let section = hosted_section(&doc, "Every release", r"^every release\s*$").body;
    let pointer: Vec<&str> = section
        .lines()
        .filter(|l| l.contains("self-update-acceptance"))
        .collect();
    assert_eq!(
        pointer.len(),
        1,
        "`## Every release` has exactly one pointer line to the checklist: {pointer:?}"
    );
    let line = pointer[0].trim_start();
    assert!(
        line.starts_with("- ") || Regex::new(r"^\d+\. ").unwrap().is_match(line),
        "the pointer is a line of the Every release list: {line}"
    );
    let target = Regex::new(r"\]\(([^)#\s]*self-update-acceptance\.md)(?:#[^)]*)?\)")
        .unwrap()
        .captures(line)
        .unwrap_or_else(|| panic!("the pointer line links the checklist as `](…)`: {line}"))[1]
        .to_string();
    let resolved = repo_root().join("docs").join(&target);
    assert!(
        resolved.is_file(),
        "the link `{target}` from docs/releasing.md resolves to a file: {}",
        resolved.display()
    );
    assert_eq!(
        resolved.canonicalize().unwrap(),
        repo_root().join(WI40_ACCEPTANCE).canonicalize().unwrap(),
        "the link points at {WI40_ACCEPTANCE}"
    );
}

// ---------- AC 7: glossary terms, no avoided terms, no home path ----------

#[test]
fn self_update_docs_use_the_glossary_terms_no_avoided_terms_and_no_home_path() {
    let upgrading = wi40_upgrading();
    let privacy = wi40_privacy();
    let acceptance = wi40_acceptance();
    let readme_text = format!("{upgrading}\n\n{privacy}");

    has_all_terms(
        "README.md Upgrading and Privacy",
        &readme_text,
        &["Self-update", "Appcast", "Release", "Bundled memex"],
    );
    has_all_terms(
        WI40_ACCEPTANCE,
        &acceptance,
        &["Self-update", "Appcast", "Release", "Bundled memex"],
    );
    wi40_assert_no_avoided_terms("README.md Upgrading and Privacy", &readme_text);
    wi40_assert_no_avoided_terms(WI40_ACCEPTANCE, &acceptance);

    // No home-directory path: not in the README's new text, and in the
    // checklist only the placeholders `/Applications/Open Memex.app` and
    // `/vaults/My Vault`.
    assert_eq!(
        non_placeholder_home_paths(&readme_text),
        Vec::<String>::new(),
        "README Upgrading and Privacy name no real home path"
    );
    for (name, text) in [
        ("README.md Upgrading and Privacy", &readme_text),
        (WI40_ACCEPTANCE, &acceptance),
    ] {
        assert!(
            !text.contains("/Users/") && !text.contains("~/"),
            "{name} names no home-directory path"
        );
    }
    assert!(
        acceptance.contains("/Applications/Open Memex.app"),
        "the checklist names the placeholder install path /Applications/Open Memex.app"
    );
}
