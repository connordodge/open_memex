//! WI #16 (R13): the `review_daily_notes` and `capture` MCP prompts.
//!
//! - The prompt texts exist once, as `memex_mcp::prompts::{REVIEW_DAILY_NOTES,
//!   CAPTURE}` (D18). The MCP server advertises the prompts capability and
//!   serves each constant byte-for-byte as a single user message.
//! - The texts carry the Spec Req 67 steps, the Req 21 change-entry rules and
//!   the Req 72/73 never-rewrite rules, in GLOSSARY.md terms, and name only
//!   tools and fields the Spec defines (tests check names, not that the tools
//!   exist yet).
//! - Composing the prompt router keeps the existing tools listed and working.
//!
//! The server is driven as a `memex serve` subprocess over newline-delimited
//! JSON-RPC, as `mcp_scaffolding.rs` does. No model is called (Req 71).

use std::collections::BTreeSet;
use std::io::{BufRead, BufReader, Write};
use std::process::{Child, ChildStdin, Command, Stdio};
use std::sync::mpsc::{self, Receiver};
use std::time::Duration;

use memex_core::Vault;
use memex_mcp::prompts::{CAPTURE, REVIEW_DAILY_NOTES};
use regex::Regex;
use serde_json::{json, Value};
use tempfile::TempDir;

// ---------- harness: `memex serve` over stdio ----------

/// A `memex serve` subprocess spoken to over newline-delimited JSON-RPC.
struct Server {
    child: Child,
    stdin: ChildStdin,
    lines: Receiver<String>,
    next_id: i64,
    /// The `result` of the `initialize` handshake.
    init: Value,
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
            init: Value::Null,
        };
        let init = server.request(
            "initialize",
            json!({
                "protocolVersion": "2025-03-26",
                "capabilities": {},
                "clientInfo": { "name": "wi16-test", "version": "0" },
            }),
        );
        assert!(init["result"].is_object(), "initialize failed: {init}");
        server.init = init["result"].clone();
        server.send(json!({ "jsonrpc": "2.0", "method": "notifications/initialized" }));
        server
    }

    fn send(&mut self, msg: Value) {
        writeln!(self.stdin, "{msg}").expect("write to server");
        self.stdin.flush().unwrap();
    }

    /// Sends a request and returns the whole JSON-RPC response object.
    fn request(&mut self, method: &str, params: Value) -> Value {
        let id = self.next_id;
        self.next_id += 1;
        self.send(json!({ "jsonrpc": "2.0", "id": id, "method": method, "params": params }));
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

    fn prompts(&mut self) -> Vec<Value> {
        let resp = self.request("prompts/list", json!({}));
        resp["result"]["prompts"]
            .as_array()
            .unwrap_or_else(|| panic!("prompts/list failed: {resp}"))
            .clone()
    }

    fn get_prompt(&mut self, name: &str) -> Value {
        self.request("prompts/get", json!({ "name": name }))
    }

    fn tool_names(&mut self) -> BTreeSet<String> {
        let resp = self.request("tools/list", json!({}));
        resp["result"]["tools"]
            .as_array()
            .unwrap_or_else(|| panic!("tools/list failed: {resp}"))
            .iter()
            .map(|t| t["name"].as_str().expect("tool name").to_string())
            .collect()
    }

    /// Calls a tool and parses the JSON string it returns.
    fn call_tool(&mut self, name: &str, arguments: Value) -> Value {
        let resp = self.request(
            "tools/call",
            json!({ "name": name, "arguments": arguments }),
        );
        let result = &resp["result"];
        assert!(result.is_object(), "tools/call {name} failed: {resp}");
        assert_ne!(result["isError"], json!(true), "{name} errored: {resp}");
        let text = result["content"][0]["text"]
            .as_str()
            .unwrap_or_else(|| panic!("{name} returned no text content: {resp}"));
        serde_json::from_str(text)
            .unwrap_or_else(|e| panic!("{name} returned non-JSON ({e}): {text}"))
    }
}

impl Drop for Server {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

fn served_vault() -> (TempDir, String) {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("vault");
    Vault::create(&path).unwrap();
    let path = path.to_str().unwrap().to_string();
    (dir, path)
}

// ---------- helpers over the prompt texts ----------

fn non_empty(name: &str, text: &str) {
    assert!(
        !text.trim().is_empty(),
        "the {name} prompt text in prompts.rs is empty"
    );
}

/// `name` in markdown code formatting, the way the prompts name tools.
fn code(name: &str) -> String {
    format!("`{name}`")
}

fn assert_contains(prompt: &str, text: &str, needle: &str) {
    assert!(
        text.contains(needle),
        "the {prompt} prompt must contain {needle:?}:\n{text}"
    );
}

fn assert_contains_ci(prompt: &str, text: &str, needle: &str) {
    assert!(
        text.to_lowercase().contains(&needle.to_lowercase()),
        "the {prompt} prompt must contain {needle:?} (any case):\n{text}"
    );
}

fn assert_matches(prompt: &str, text: &str, pattern: &str) {
    let re = Regex::new(pattern).unwrap();
    assert!(
        re.is_match(text),
        "the {prompt} prompt must match /{pattern}/:\n{text}"
    );
}

/// Each name appears in code formatting, and they appear in this order (each
/// one found after the previous one's first match).
fn assert_names_in_order(prompt: &str, text: &str, names: &[&str]) {
    let mut from = 0;
    for name in names {
        let needle = code(name);
        assert!(
            text.contains(&needle),
            "the {prompt} prompt must name {needle}:\n{text}"
        );
        let found = text[from..].find(&needle).unwrap_or_else(|| {
            panic!(
                "the {prompt} prompt must name {needle} after the tools before it in {names:?}:\n{text}"
            )
        });
        from += found + needle.len();
    }
}

/// Every snake_case MCP tool name the Spec defines (existing tools, Req 14,
/// 21, 25-27, 30, 40). One block per feature: a later WI appends to its own.
const EXISTING_SPEC_TOOLS: &[&str] = &[
    "search",
    "get_note",
    "neighbors",
    "add_link",
    "create_note",
    "update_link",
    "list_canvases",
    "get_canvas",
    "create_canvas",
    "add_to_canvas",
    "remove_from_canvas",
    "move_node",
    "delete_canvas",
    "list_unreviewed_days",
    "get_daily_note_changes",
    "mark_day_reviewed",
    "get_vault_settings",
    "append_to_daily_note",
    "add_excerpt",
    "remove_excerpt",
    "list_smart_folders",
    "create_smart_folder",
    "update_smart_folder",
    "delete_smart_folder",
    "add_to_smart_folder",
    "remove_from_smart_folder",
];

/// The tag tools a prompt may name (#241 fills this block).
const TAG_SPEC_TOOLS: &[&str] = &["list_tags", "tag_note", "untag_note", "add_footer_topic"];

/// The feedback tools a prompt may name (#254 fills this block).
const FEEDBACK_SPEC_TOOLS: &[&str] = &[
    "get_vault_guide",
    "update_vault_guide",
    "list_open_feedback",
    "resolve_feedback",
    "record_feedback",
    "get_day_filing",
    "remove_excerpt_block",
];

/// Snake_case parameter, field, prompt and error-code names the Spec and
/// CONTRACTS C1/C2 define, which a prompt may also mention. One block per
/// feature: a later WI appends to its own.
const EXISTING_SPEC_FIELDS: &[&str] = &[
    "review_daily_notes",
    "note_id",
    "topic_note_id",
    "daily_note_id",
    "smart_folder_id",
    "parent_id",
    "block_ids",
    "content_md",
    "content_version",
    "reviewed_content_version",
    "prior_state",
    "smart_folder_max_depth",
    "max_depth",
    "required_depth",
    "include_backlinks",
    "agent_id",
    "vault_id",
    "version_conflict",
    "not_found",
    "title_conflict",
    "invalid_id",
    "daily_note_exists",
    "marker_rule",
    "role_rule",
    "pinned_rule",
    "depth_exceeded",
    "change_entries_invalid",
    "review_stale",
    "name_conflict",
    "folder_cycle",
    "invalid_date",
    "block_not_found",
    "setting_invalid",
    "invalid_argument",
];

/// The tag fields a prompt may name (#243 fills this block): the error codes
/// `tag_note` returns that the prompts tell the agent how to handle.
const TAG_SPEC_FIELDS: &[&str] = &["unknown_tag", "tag_removed", "guide_rule"];

/// The feedback fields a prompt may name: the error codes and Contract fields of
/// #254's tools. #257 appends what its prompts add.
const FEEDBACK_SPEC_FIELDS: &[&str] = &[
    "guide_rule",
    "feedback_handled",
    "feedback_invalid",
    "block_id",
    "not_filed",
    "agent_change_id",
    "handled_at",
    "excerpt_moved",
    "excerpt_removed",
    "excerpt_added",
    "membership_removed",
    "folder_renamed",
    "folder_moved",
    "folder_deleted",
    "tag_removed",
];

/// Any snake_case identifier in the text must be a Spec tool or field name, so
/// an agent is never told to call a tool that the Spec does not define.
fn assert_only_spec_identifiers(prompt: &str, text: &str) {
    let known: BTreeSet<&str> = [
        EXISTING_SPEC_TOOLS,
        TAG_SPEC_TOOLS,
        FEEDBACK_SPEC_TOOLS,
        EXISTING_SPEC_FIELDS,
        TAG_SPEC_FIELDS,
        FEEDBACK_SPEC_FIELDS,
    ]
    .into_iter()
    .flatten()
    .copied()
    .collect();
    let re = Regex::new(r"\b[a-z][a-z0-9]*(?:_[a-z0-9]+)+\b").unwrap();
    let unknown: BTreeSet<&str> = re
        .find_iter(text)
        .map(|m| m.as_str())
        .filter(|id| !known.contains(id))
        .collect();
    assert!(
        unknown.is_empty(),
        "the {prompt} prompt names identifiers the Spec does not define: {unknown:?}"
    );
}

/// Some `never` is followed, within one sentence-sized window, by all of the
/// Req 72/73 verbs and the person's text.
fn assert_never_rewrites(prompt: &str, text: &str) {
    let lower = text.to_lowercase();
    let verbs = [
        Regex::new(r"rewrit").unwrap(),
        Regex::new(r"reorder").unwrap(),
        Regex::new(r"delet").unwrap(),
        Regex::new(r"summari[sz]").unwrap(),
        Regex::new(r"merg").unwrap(),
        Regex::new(r"person").unwrap(),
    ];
    let found = lower.match_indices("never").any(|(i, _)| {
        let end = (i + 260).min(lower.len());
        let window = &lower[i..end];
        verbs.iter().all(|v| v.is_match(window))
    });
    assert!(
        found,
        "the {prompt} prompt must say never to rewrite, reorder, delete, summarise or merge \
         the person's text (all in one sentence after `never`):\n{text}"
    );
}

// ---------- AC 1: capability and listing ----------

#[test]
fn server_advertises_prompts_and_lists_exactly_review_and_capture() {
    let (_dir, vault) = served_vault();
    let mut server = Server::start(&vault);
    assert!(
        server.init["capabilities"]["prompts"].is_object(),
        "initialize must advertise the prompts capability: {}",
        server.init
    );

    let prompts = server.prompts();
    let names: Vec<&str> = prompts
        .iter()
        .map(|p| p["name"].as_str().expect("prompt name"))
        .collect();
    let unique: BTreeSet<&str> = names.iter().copied().collect();
    assert_eq!(names.len(), 2, "exactly two prompts: {names:?}");
    assert_eq!(
        unique,
        BTreeSet::from(["review_daily_notes", "capture"]),
        "{names:?}"
    );
    for p in &prompts {
        let description = p["description"].as_str().unwrap_or("");
        assert!(
            !description.trim().is_empty(),
            "prompt {} must have a description: {p}",
            p["name"]
        );
    }
}

// ---------- AC 2: get returns the constants byte-for-byte ----------

#[test]
fn get_prompt_returns_each_constant_as_a_single_user_message() {
    non_empty("review", REVIEW_DAILY_NOTES);
    non_empty("capture", CAPTURE);
    assert_ne!(REVIEW_DAILY_NOTES, CAPTURE, "the two prompts differ");

    let (_dir, vault) = served_vault();
    let mut server = Server::start(&vault);
    for (name, expected) in [
        ("review_daily_notes", REVIEW_DAILY_NOTES),
        ("capture", CAPTURE),
    ] {
        let resp = server.get_prompt(name);
        let messages = resp["result"]["messages"]
            .as_array()
            .unwrap_or_else(|| panic!("prompts/get {name} failed: {resp}"));
        assert_eq!(messages.len(), 1, "{name}: one message: {resp}");
        let message = &messages[0];
        assert_eq!(message["role"], "user", "{name}: {message}");
        assert_eq!(message["content"]["type"], "text", "{name}: {message}");
        let text = message["content"]["text"]
            .as_str()
            .unwrap_or_else(|| panic!("{name}: text content: {message}"));
        assert_eq!(
            text.as_bytes(),
            expected.as_bytes(),
            "{name} must be the prompts.rs constant byte-for-byte"
        );
    }

    // The CLI names are not MCP prompt names.
    for name in ["review", "bogus"] {
        let resp = server.get_prompt(name);
        assert!(
            resp["error"].is_object() && resp.get("result").is_none(),
            "prompts/get {name:?} must be a JSON-RPC error: {resp}"
        );
    }
}

// ---------- AC 3: review steps ----------

#[test]
fn review_prompt_names_the_tools_in_workflow_order() {
    non_empty("review", REVIEW_DAILY_NOTES);
    assert_names_in_order(
        "review",
        REVIEW_DAILY_NOTES,
        &[
            "list_unreviewed_days",
            "get_daily_note_changes",
            "search",
            "add_excerpt",
            "add_link",
            "add_to_smart_folder",
            "mark_day_reviewed",
        ],
    );
}

#[test]
fn review_prompt_states_oldest_first_search_first_depth_pinned_and_repeat() {
    let text = REVIEW_DAILY_NOTES;
    non_empty("review", text);

    // Take the oldest day first.
    assert_contains_ci("review", text, "oldest");

    // Search for a matching topic note before creating one.
    assert_contains_ci("review", text, "before creating");
    let search = text.find(&code("search"));
    let create = text.find(&code("create_note"));
    assert!(
        matches!((search, create), (Some(s), Some(c)) if s < c),
        "the review prompt must name `search` before `create_note`:\n{text}"
    );
    assert_matches("review", text, r#"role:\s*"?topic"?"#);

    // Stay within the Smart Folder depth limit, read from get_vault_settings.
    assert_contains("review", text, &code("get_vault_settings"));
    assert_contains_ci("review", text, "depth limit");
    assert_contains("review", text, "Smart Folder");

    // Respect pinned items.
    assert_contains_ci("review", text, "pinned");

    // Repeat until no unreviewed days remain.
    assert_contains_ci("review", text, "repeat");
    assert_contains_ci("review", text, "no unreviewed days");
}

// ---------- AC 4: change-entry rules (Req 21) ----------

#[test]
fn review_prompt_states_the_change_entry_rules() {
    let text = REVIEW_DAILY_NOTES;
    non_empty("review", text);
    assert_matches("review", text, r"(?i)\bentry (per|for each|for every)\b");
    assert_contains_ci("review", text, "touched");
    assert_contains_ci("review", text, "daily note itself");
    assert_contains("review", text, "1 to 3 bullets");
    assert_matches("review", text, r"(?i)\b(one|single) line\b");
    assert_contains_ci("review", text, "at most 200 characters");
    assert_contains("review", text, "`- `");
}

// ---------- AC 5: capture steps ----------

#[test]
fn capture_prompt_appends_verbatim_files_and_marks_reviewed_only_from_reviewed() {
    let text = CAPTURE;
    non_empty("capture", text);

    // Each message is an observation, appended verbatim to today's daily note.
    assert_contains_ci("capture", text, "each message");
    assert_contains_ci("capture", text, "observation");
    assert_contains_ci("capture", text, "verbatim");
    assert_contains_ci("capture", text, "today's daily note");

    // Append, then file the returned blocks, then mark reviewed.
    assert_names_in_order(
        "capture",
        text,
        &["append_to_daily_note", "add_excerpt", "mark_day_reviewed"],
    );
    assert_contains_ci("capture", text, "returned blocks");

    // Mark reviewed with the returned version only when prior_state is Reviewed.
    assert_matches(
        "capture",
        text,
        r"(?i)(returned (content )?version|version (it |that )?returned)",
    );
    assert_matches(
        "capture",
        text,
        r"(?is)only (when|if)\b.{0,40}`prior_state`.{0,20}`Reviewed`",
    );

    // Otherwise run a full review of the day.
    assert_contains("capture", text, "`Unreviewed`");
    assert_contains("capture", text, "`Changed since review`");
    assert_contains_ci("capture", text, "version check");
    assert_contains_ci("capture", text, "full review");

    // Reply in one line saying where the observation went.
    assert_contains_ci("capture", text, "reply");
    assert_contains_ci("capture", text, "one line");
    assert_contains_ci("capture", text, "where");
}

// ---------- AC 6: never rewrite the person's text (Req 72, 73) ----------

#[test]
fn both_prompts_forbid_rewriting_reordering_deleting_summarising_or_merging() {
    for (prompt, text) in [("review", REVIEW_DAILY_NOTES), ("capture", CAPTURE)] {
        non_empty(prompt, text);
        assert_never_rewrites(prompt, text);
    }
}

// ---------- AC 3/5: names and vocabulary match the Spec and GLOSSARY.md ----------

#[test]
fn prompts_name_only_spec_tools_and_fields() {
    non_empty("review", REVIEW_DAILY_NOTES);
    non_empty("capture", CAPTURE);
    for tool in [
        "list_unreviewed_days",
        "get_daily_note_changes",
        "search",
        "get_note",
        "create_note",
        "add_excerpt",
        "add_link",
        "get_vault_settings",
        "list_smart_folders",
        "create_smart_folder",
        "add_to_smart_folder",
        "mark_day_reviewed",
    ] {
        assert_contains("review", REVIEW_DAILY_NOTES, &code(tool));
    }
    for tool in ["append_to_daily_note", "add_excerpt", "mark_day_reviewed"] {
        assert_contains("capture", CAPTURE, &code(tool));
    }
    assert_only_spec_identifiers("review", REVIEW_DAILY_NOTES);
    assert_only_spec_identifiers("capture", CAPTURE);
}

#[test]
fn prompts_use_glossary_terms() {
    non_empty("review", REVIEW_DAILY_NOTES);
    non_empty("capture", CAPTURE);
    for term in [
        "daily note",
        "topic note",
        "Smart Folder",
        "excerpt",
        "pinned",
    ] {
        assert_contains("review", REVIEW_DAILY_NOTES, term);
    }
    for term in ["daily note", "topic note", "observation"] {
        assert_contains("capture", CAPTURE, term);
    }

    // Glossary spellings: always `Smart Folder` and `Note footer`.
    let smart_folder = Regex::new(r"(?i)\bsmart folders?\b").unwrap();
    let note_footer = Regex::new(r"(?i)\bnote footer\b").unwrap();
    // Glossary `_Avoid_` terms for the concepts these prompts talk about.
    let avoid = Regex::new(
        r"(?i)\b(journal|day page|snippet|subject note|concept note|inbox|dictation|quick add|organi[sz]\w*|links section|user-owned)\b",
    )
    .unwrap();
    for (prompt, text) in [("review", REVIEW_DAILY_NOTES), ("capture", CAPTURE)] {
        for m in smart_folder.find_iter(text) {
            assert!(
                m.as_str().starts_with("Smart Folder"),
                "the {prompt} prompt must spell it `Smart Folder`, not {:?}",
                m.as_str()
            );
        }
        for m in note_footer.find_iter(text) {
            assert_eq!(m.as_str(), "Note footer", "the {prompt} prompt's spelling");
        }
        let bad: Vec<&str> = avoid.find_iter(text).map(|m| m.as_str()).collect();
        assert!(
            bad.is_empty(),
            "the {prompt} prompt uses GLOSSARY.md _Avoid_ terms: {bad:?}"
        );
    }
}

// ---------- AC 9: tools still list and work beside the prompts ----------

#[test]
fn tools_still_list_and_work_alongside_prompts() {
    let (_dir, vault) = served_vault();
    let mut server = Server::start(&vault);
    let caps = &server.init["capabilities"];
    assert!(caps["tools"].is_object(), "tools capability kept: {caps}");
    assert!(
        caps["prompts"].is_object(),
        "prompts capability added: {caps}"
    );

    let tools = server.tool_names();
    for name in [
        "search",
        "get_note",
        "neighbors",
        "add_link",
        "create_note",
        "list_canvases",
        "get_canvas",
        "create_canvas",
        "add_to_canvas",
        "remove_from_canvas",
        "move_node",
        "delete_canvas",
        "update_link",
    ] {
        assert!(tools.contains(name), "tool {name} still listed: {tools:?}");
    }
    assert!(
        !tools.contains("review_daily_notes") && !tools.contains("capture"),
        "prompts are not tools: {tools:?}"
    );

    let created = server.call_tool(
        "create_note",
        json!({ "title": "Player Loop", "content_md": "# Player Loop\n\nThe core loop." }),
    );
    let note_id = created["note_id"]
        .as_str()
        .unwrap_or_else(|| panic!("create_note: {created}"))
        .to_string();
    let got = server.call_tool("get_note", json!({ "note_id": note_id }));
    assert_eq!(got["title"], "Player Loop", "{got}");
    assert_eq!(got["note_id"], json!(note_id), "{got}");

    // Prompts are served by the same server after tools were used.
    assert_eq!(server.prompts().len(), 2);
}

// ======================================================================
// WI #243 (Spec #234 R41-R44): the tagging rules in both prompts.
//
// Review gets one new unnumbered section between the numbered steps plus the
// `Tagged #name` bullet in step 7; steps 1-8 keep their numbers (D22). Capture
// gets the rules in its own text. Helpers carry a `wi243_` prefix.
// ======================================================================

/// `(heading, body)` of each `## ` section of a prompt, in order. The body
/// runs to the next `## ` line or the end.
fn wi243_sections(text: &str) -> Vec<(String, String)> {
    let mut out: Vec<(String, String)> = Vec::new();
    for line in text.lines() {
        if let Some(heading) = line.strip_prefix("## ") {
            out.push((heading.trim().to_string(), String::new()));
        } else if let Some((_, body)) = out.last_mut() {
            body.push_str(line);
            body.push('\n');
        }
    }
    out
}

/// The Review prompt's one unnumbered section whose heading names tagging.
fn wi243_review_tagging_section() -> String {
    let numbered = Regex::new(r"^\d+\.").unwrap();
    let tagging: Vec<(String, String)> = wi243_sections(REVIEW_DAILY_NOTES)
        .into_iter()
        .filter(|(h, _)| !numbered.is_match(h) && h.to_lowercase().contains("tag"))
        .collect();
    assert_eq!(
        tagging.len(),
        1,
        "the review prompt must have exactly one unnumbered `## ` section whose heading \
         names tagging; found {:?}:\n{REVIEW_DAILY_NOTES}",
        tagging.iter().map(|(h, _)| h).collect::<Vec<_>>()
    );
    let (heading, body) = &tagging[0];
    format!("## {heading}\n{body}")
}

/// The Review prompt's step 7 section.
fn wi243_review_step_seven() -> String {
    let (heading, body) = wi243_sections(REVIEW_DAILY_NOTES)
        .into_iter()
        .find(|(h, _)| h.starts_with("7."))
        .expect("the review prompt has a `## 7.` section");
    format!("## {heading}\n{body}")
}

/// Both prompts' common tagging rules: `list_tags` once, `tag_note` only the
/// listed tags, no listed tags means none, never `#tag` in a body.
fn wi243_assert_common_tagging_rules(prompt: &str, text: &str) {
    assert_names_in_order(prompt, text, &["list_tags", "tag_note"]);
    assert_matches(prompt, text, r"(?is)`list_tags`[^.]{0,80}\bonce\b");
    assert_matches(
        prompt,
        text,
        r"(?is)\bonly\b[^.]{0,80}\blist(ed|s)\b|\blisted\b[^.]{0,80}\bonly\b",
    );
    assert_matches(
        prompt,
        text,
        r"(?is)(no (listed )?tags|lists? no tags|empty)[^.]{0,120}\b(none|no tag|skip|do not|don't|never)\b",
    );
    assert_matches(
        prompt,
        text,
        r"(?is)\bnever\b[^.]{0,120}`#tag`|`#tag`[^.]{0,120}\bnever\b",
    );
    assert_contains_ci(prompt, text, "body");
    assert_matches(prompt, text, r"(?i)\btouch(ed|es)?\b");
    assert_matches(
        prompt,
        text,
        r"(?i)\b(no|any) other notes?\b|\bother notes\b",
    );
}

/// The three error codes, each in code formatting, with the rule: leave that
/// tag, carry on, do not retry; a removed tag is the person's doing.
fn wi243_assert_tag_error_rules(prompt: &str, text: &str) {
    for code in ["unknown_tag", "tag_removed", "guide_rule"] {
        assert_contains(prompt, text, &format!("`{code}`"));
    }
    assert_matches(prompt, text, r"(?i)\b(do not|don't|never) retry\b");
    assert_matches(
        prompt,
        text,
        r"(?i)carry on|leave (that|the|it) tag|leave it",
    );
    assert_matches(
        prompt,
        text,
        r"(?is)(removed tag|`tag_removed`)[^.]{0,160}\bperson\b",
    );
}

#[test]
fn review_prompt_keeps_steps_one_to_eight_and_adds_one_unnumbered_tagging_section_between_them() {
    let text = REVIEW_DAILY_NOTES;
    let numbered = Regex::new(r"(?m)^## (\d+)\. (.+)$").unwrap();
    let steps: Vec<(u32, String)> = numbered
        .captures_iter(text)
        .map(|c| (c[1].parse().unwrap(), c[2].to_string()))
        .collect();
    assert_eq!(
        steps.iter().map(|(n, _)| *n).collect::<Vec<_>>(),
        (1..=8).collect::<Vec<u32>>(),
        "steps 1-8 keep their numbers (D22), none added or renumbered:\n{text}"
    );
    assert_eq!(steps[6].1, "Mark the day reviewed");
    assert_eq!(steps[7].1, "Repeat");

    let section = wi243_review_tagging_section();
    let at = text.find(&section).expect("the section is in the prompt");
    let step1 = text.find("## 1. ").unwrap();
    let step8 = text.find("## 8. ").unwrap();
    assert!(
        step1 < at && at < step8,
        "the tagging section sits between the numbered steps, not before step 1 \
         (another WI's section) and not after step 8:\n{text}"
    );
}

#[test]
fn review_tagging_section_names_list_tags_once_and_limits_tag_note_to_the_day_and_touched_topic_notes(
) {
    let section = wi243_review_tagging_section();
    wi243_assert_common_tagging_rules("review", &section);
    assert_contains("review", &section, "daily note");
    assert_contains("review", &section, "topic note");
    assert_contains_ci("review", &section, "note as a whole");
}

#[test]
fn review_tagging_section_says_never_add_text_to_a_daily_note_and_never_write_a_hash_tag_into_a_body(
) {
    let section = wi243_review_tagging_section();
    assert_matches("review", &section, r"(?i)never add text to a daily note");
    assert_matches(
        "review",
        &section,
        r"(?is)\bnever\b[^.]{0,120}`#tag`[^.]{0,80}\bbody\b",
    );
}

#[test]
fn review_prompt_tells_the_agent_what_to_do_on_unknown_tag_tag_removed_and_guide_rule() {
    wi243_assert_tag_error_rules("review", &wi243_review_tagging_section());
}

#[test]
fn capture_prompt_tells_the_agent_what_to_do_on_unknown_tag_tag_removed_and_guide_rule() {
    wi243_assert_tag_error_rules("capture", CAPTURE);
}

#[test]
fn review_step_seven_shows_the_tagged_bullet_and_asks_an_entry_for_a_note_touched_only_by_tagging()
{
    let step = wi243_review_step_seven();
    assert_matches("review step 7", &step, r"`Tagged #[a-z][a-z0-9-]*`");
    assert_matches(
        "review step 7",
        &step,
        r"(?i)only (by|through|with) tagging|tag-only|tagging alone|only tagged|only a tag was",
    );
    assert_contains_ci("review step 7", &step, "entry");
    // The rules already there stay.
    assert_contains("review step 7", &step, "1 to 3 bullets");
    assert_contains("review step 7", &step, "`change_entries_invalid`");
    assert_contains("review step 7", &step, "`review_stale`");
}

#[test]
fn capture_prompt_applies_the_same_tagging_rules_to_the_notes_it_touches() {
    let text = CAPTURE;
    wi243_assert_common_tagging_rules("capture", text);
    // The same change-entry bullet, since capture marks the day reviewed too.
    assert_matches("capture", text, r"`Tagged #[a-z][a-z0-9-]*`");
    // The rule lives in capture's own text: the opening paragraphs (another
    // WI's lines) do not name the tagging tools.
    let opening = text
        .split("For each message:")
        .next()
        .expect("capture has a `For each message:` line");
    assert!(
        !opening.contains("list_tags") && !opening.contains("tag_note"),
        "capture's tagging rule belongs after `For each message:`, not in its opening \
         paragraphs:\n{text}"
    );
}

#[test]
fn both_prompts_with_tagging_name_only_spec_identifiers_and_no_system_tag_names() {
    let avoid = Regex::new(r"(?i)\binbox\b|agent-authored|organi[sz]\w*").unwrap();
    for (prompt, text) in [("review", REVIEW_DAILY_NOTES), ("capture", CAPTURE)] {
        assert_contains(prompt, text, &code("list_tags"));
        assert_contains(prompt, text, &code("tag_note"));
        assert_only_spec_identifiers(prompt, text);
        let bad: Vec<&str> = avoid.find_iter(text).map(|m| m.as_str()).collect();
        assert!(
            bad.is_empty(),
            "the {prompt} prompt names system tags or uses an avoided term: {bad:?}"
        );
    }
}

// ======================================================================
// WI #257 (Spec #233 R34-R38, D22, D44): Feedback and the Vault Guide in the
// prompts.
//
// Review gets one new unnumbered section between `## Ground rules` and
// `## 1.` plus one ground-rule bullet and a step 1 stop line that ends the run
// after the Feedback work; steps 1-8 keep their numbers. Capture reads the
// guide in its opening paragraph and never writes it. Tests pin required
// phrases, not whole paragraphs. Helpers carry a `wi257_` prefix.
// ======================================================================

/// The eight numbered step headings, exactly as they were before this WI.
const WI257_STEP_HEADINGS: [&str; 8] = [
    "1. Take the oldest unreviewed day",
    "2. Fetch what changed",
    "3. Group the blocks by subject",
    "4. Find or create the topic note for each subject",
    "5. Add excerpts",
    "6. Link topic notes and place them in Smart Folders",
    "7. Mark the day reviewed",
    "8. Repeat",
];

/// The `## ` headings of the Review prompt, in order.
fn wi257_review_headings() -> Vec<String> {
    wi243_sections(REVIEW_DAILY_NOTES)
        .into_iter()
        .map(|(h, _)| h)
        .collect()
}

/// The Review prompt's one unnumbered section whose heading names Feedback, as
/// one string: the heading line, then the body.
fn wi257_feedback_section() -> String {
    let numbered = Regex::new(r"^\d+\.").unwrap();
    let found: Vec<(String, String)> = wi243_sections(REVIEW_DAILY_NOTES)
        .into_iter()
        .filter(|(h, _)| !numbered.is_match(h) && h.to_lowercase().contains("feedback"))
        .collect();
    assert_eq!(
        found.len(),
        1,
        "the review prompt must have exactly one unnumbered `## ` section whose heading \
         names Feedback (suggested: `## Feedback and the Vault Guide`); found {:?}:\n{REVIEW_DAILY_NOTES}",
        found.iter().map(|(h, _)| h).collect::<Vec<_>>()
    );
    let (heading, body) = &found[0];
    format!("## {heading}\n{body}")
}

/// The body of the Review prompt's `## Ground rules` section.
fn wi257_ground_rules() -> String {
    wi243_sections(REVIEW_DAILY_NOTES)
        .into_iter()
        .find(|(h, _)| h == "Ground rules")
        .map(|(_, body)| body)
        .expect("the review prompt has a `## Ground rules` section")
}

/// The body of the Review prompt's step 1 section.
fn wi257_step_one() -> String {
    wi243_sections(REVIEW_DAILY_NOTES)
        .into_iter()
        .find(|(h, _)| h.starts_with("1. "))
        .map(|(_, body)| body)
        .expect("the review prompt has a `## 1.` section")
}

/// Capture's opening paragraphs: everything before `For each message:`.
fn wi257_capture_opening() -> String {
    CAPTURE
        .split("For each message:")
        .next()
        .expect("capture has a `For each message:` line")
        .to_string()
}

fn wi257_repo_file(rel: &str) -> String {
    let path = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("..")
        .join("..")
        .join(rel);
    std::fs::read_to_string(&path).unwrap_or_else(|e| panic!("read {}: {e}", path.display()))
}

#[test]
fn review_prompt_adds_one_unnumbered_feedback_section_between_ground_rules_and_step_one_and_keeps_steps_one_to_eight(
) {
    let headings = wi257_review_headings();
    let numbered = Regex::new(r"^\d+\.").unwrap();
    let steps: Vec<&str> = headings
        .iter()
        .filter(|h| numbered.is_match(h))
        .map(String::as_str)
        .collect();
    assert_eq!(
        steps, WI257_STEP_HEADINGS,
        "steps 1-8 keep their headings and numbers (D22); none added, renumbered or renamed"
    );

    // Ground rules, the new section, then step 1: the section is before step 1.
    assert_eq!(headings[0], "Ground rules", "{headings:?}");
    assert!(
        headings[1].to_lowercase().contains("feedback") && !numbered.is_match(&headings[1]),
        "an unnumbered Feedback section follows `## Ground rules`: {headings:?}"
    );
    assert_eq!(headings[2], WI257_STEP_HEADINGS[0], "{headings:?}");

    // Exactly one new section: the 8 steps, Ground rules, the tagging section
    // (another WI's) and this one.
    assert_eq!(headings.len(), 11, "{headings:?}");
    let text = REVIEW_DAILY_NOTES;
    let section = wi257_feedback_section();
    let at = text.find(&section).expect("the section is in the prompt");
    let ground = text.find("## Ground rules").unwrap();
    let step1 = text.find("## 1. ").unwrap();
    assert!(
        ground < at && at < step1,
        "the Feedback section sits between `## Ground rules` and `## 1.`:\n{text}"
    );
}

#[test]
fn review_feedback_section_names_the_five_feedback_tools_in_the_order_a_pass_uses_them() {
    let section = wi257_feedback_section();
    assert_names_in_order(
        "review Feedback section",
        &section,
        &[
            "get_vault_guide",
            "list_open_feedback",
            "update_vault_guide",
            "resolve_feedback",
        ],
    );
    for tool in ["record_feedback", "remove_excerpt_block", "add_excerpt"] {
        assert_contains("review Feedback section", &section, &code(tool));
    }
    // The section comes before step 1, so none of these is only in a later step.
    let before_step_one = &REVIEW_DAILY_NOTES[..REVIEW_DAILY_NOTES.find("## 1. ").unwrap()];
    for tool in [
        "get_vault_guide",
        "list_open_feedback",
        "resolve_feedback",
        "update_vault_guide",
        "record_feedback",
    ] {
        assert_contains("review, before step 1", before_step_one, &code(tool));
    }
}

#[test]
fn review_feedback_section_reads_the_guide_and_works_open_feedback_oldest_first_even_with_no_unreviewed_days(
) {
    let section = wi257_feedback_section();
    // The guide is read and followed when filing.
    assert_matches(
        "review Feedback section",
        &section,
        r"(?is)`get_vault_guide`[^.]{0,160}\bfollow\w*\b|\bfollow\w*\b[^.]{0,160}`get_vault_guide`",
    );
    assert_matches(
        "review Feedback section",
        &section,
        r"(?i)\bwhen filing\b|\bwhen you file\b",
    );
    // Open Feedback, oldest first.
    assert_matches(
        "review Feedback section",
        &section,
        r"(?is)`list_open_feedback`[^.]{0,200}\boldest first\b",
    );
    // Worked through even when no days are unreviewed (for example: "even when
    // no days are unreviewed", "even if there are no unreviewed days").
    assert_matches(
        "review Feedback section",
        &section,
        r"(?is)\beven (when|if)\b[^.]{0,80}(\bno\b[^.]{0,40}\bunreviewed\b|\bunreviewed\b[^.]{0,40}\b(none|empty)\b|\bempty\b)",
    );
}

#[test]
fn review_feedback_section_tells_the_agent_to_fix_a_named_filing_within_the_pinned_rules_and_place_a_person_created_topic_note(
) {
    let section = wi257_feedback_section();
    // One block moves with `remove_excerpt_block` plus `add_excerpt`.
    assert_matches(
        "review Feedback section",
        &section,
        r"(?is)`remove_excerpt_block`[^.]{0,120}`add_excerpt`",
    );
    assert_matches(
        "review Feedback section",
        &section,
        r"(?i)\bone block\b|\bsingle block\b|\bthat block\b",
    );
    assert_contains_ci("review Feedback section", &section, "pinned");
    // A person-created topic note a Correction names, that is in no Smart Folder.
    assert_contains(
        "review Feedback section",
        &section,
        "person-created topic note",
    );
    assert_contains(
        "review Feedback section",
        &section,
        &code("add_to_smart_folder"),
    );
    assert_matches(
        "review Feedback section",
        &section,
        r"(?i)\bin no Smart Folder\b|\bnot in any Smart Folder\b|\bno Smart Folder\b",
    );
    // A lasting preference goes into the guide.
    assert_matches(
        "review Feedback section",
        &section,
        r"(?is)\blasting\b[^.]{0,160}`update_vault_guide`|`update_vault_guide`[^.]{0,160}\blasting\b",
    );
}

#[test]
fn review_feedback_section_marks_each_item_handled_with_a_one_line_reply_that_never_quotes_or_summarises_the_persons_text(
) {
    let section = wi257_feedback_section();
    assert_contains("review Feedback section", &section, "Handled");
    assert_matches(
        "review Feedback section",
        &section,
        r"(?is)\bHandled\b[^.]{0,60}`resolve_feedback`|`resolve_feedback`[^.]{0,60}\bHandled\b",
    );
    assert_matches(
        "review Feedback section",
        &section,
        r"(?is)\bone[- ]line\b[^.]{0,40}\breply\b|\breply\b[^.]{0,40}\bone[- ]line\b",
    );
    // What you did, or why you could not.
    assert_matches(
        "review Feedback section",
        &section,
        r"(?is)\bwhat you did\b[^.]{0,80}\bwhy you (could not|couldn't|cannot)\b",
    );
    // Never quote or summarise the person's text.
    assert_matches(
        "review Feedback section",
        &section,
        r"(?is)\bnever\b[^.]{0,40}\bquot\w*\b[^.]{0,40}\bsummari[sz]\w*\b[^.]{0,40}\bperson\b",
    );
}

#[test]
fn review_feedback_section_carries_on_when_resolve_feedback_returns_not_found_because_the_person_deleted_it(
) {
    let section = wi257_feedback_section();
    assert_matches(
        "review Feedback section",
        &section,
        r"(?is)`resolve_feedback`[^.]{0,60}`not_found`[^.]{0,80}\bdeleted\b[^.]{0,40}\bcarry on\b",
    );
}

#[test]
fn review_feedback_section_does_not_sweep_older_days_unless_the_feedback_asks() {
    let section = wi257_feedback_section();
    assert_matches(
        "review Feedback section",
        &section,
        r"(?is)\bdo not\b[^.]{0,40}\bsweep\b[^.]{0,60}\bolder days?\b[^.]{0,40}\bunless\b[^.]{0,40}\bFeedback\b",
    );
}

#[test]
fn review_prompt_says_never_to_redo_a_correction_and_that_the_latest_correction_per_block_is_final()
{
    let text = REVIEW_DAILY_NOTES;
    assert_contains("review", text, "Correction");
    // The latest Correction per block is final.
    assert_matches(
        "review",
        text,
        r"(?is)\blatest Correction\b[^.]{0,40}\bper block\b[^.]{0,40}\bfinal\b",
    );
    // Never re-file a block, or re-add a topic note to a Smart Folder, that the
    // person took it out of.
    assert_matches(
        "review",
        text,
        r"(?is)\bnever\b[^.]{0,30}\bre-?fil\w*\b[^.]{0,80}\bblock\b[^.]{0,80}\btopic note\b[^.]{0,80}\bperson\b[^.]{0,40}\btook\b",
    );
    assert_matches(
        "review",
        text,
        r"(?is)\bre-?add\w*\b[^.]{0,60}\btopic note\b[^.]{0,40}\bSmart Folder\b[^.]{0,80}\bperson\b[^.]{0,40}\btook\b",
    );
    // Unless the block's text has changed so much that it clearly belongs there now.
    assert_matches(
        "review",
        text,
        r"(?is)\bunless\b[^.]{0,60}\btext has changed\b[^.]{0,80}\bclearly belongs\b",
    );
    // No server block: it is the agent's judgment.
    assert_matches(
        "review",
        text,
        r"(?is)\bno server\b[^.]{0,40}\bblock\b[^.]{0,80}\bjudg(e)?ment\b",
    );
}

#[test]
fn review_feedback_section_treats_a_comment_about_filing_during_a_session_as_feedback() {
    let section = wi257_feedback_section();
    assert_matches(
        "review Feedback section",
        &section,
        r"(?is)\bsession\b[^.]{0,120}\bcomment\b[^.]{0,80}\bfiling\b[^.]{0,60}\bFeedback\b",
    );
    // Fix it on the spot, record it word for word, update the guide if lasting.
    assert_contains_ci("review Feedback section", &section, "on the spot");
    assert_matches(
        "review Feedback section",
        &section,
        r"(?is)\bword for word\b[^.]{0,40}`record_feedback`|`record_feedback`[^.]{0,60}\bword for word\b",
    );
    assert_matches(
        "review Feedback section",
        &section,
        r"(?is)`update_vault_guide`[^.]{0,60}\blasting\b|\blasting\b[^.]{0,100}`update_vault_guide`",
    );
    // Fixes outside `mark_day_reviewed` go in `changes`.
    assert_matches(
        "review Feedback section",
        &section,
        r"(?is)\boutside\b[^.]{0,20}`mark_day_reviewed`[^.]{0,60}`changes`",
    );
}

#[test]
fn review_ground_rules_gain_one_bullet_naming_the_vault_guide_as_the_one_exception_to_never_rewrite(
) {
    let rules = wi257_ground_rules();
    let bullets: Vec<&str> = rules.lines().filter(|l| l.starts_with("- ")).collect();
    assert_eq!(
        bullets.len(),
        4,
        "`## Ground rules` had three bullets and gains exactly one:\n{rules}"
    );
    let with_guide: Vec<&&str> = bullets
        .iter()
        .filter(|b| b.contains("Vault Guide"))
        .collect();
    assert_eq!(
        with_guide.len(),
        1,
        "exactly one ground rule names the Vault Guide: {bullets:?}"
    );
    let bullet = with_guide[0];
    assert_matches("review ground rule", bullet, r"(?i)\bexception\b");
    assert_matches("review ground rule", bullet, r"(?i)\brewrit\w*\b");
    assert_matches("review ground rule", bullet, r"(?i)\bany of it\b");
    assert_contains("review ground rule", bullet, "200 lines");
    assert_contains_ci("review ground rule", bullet, "short");
    // The rule it is an exception to stays in force.
    assert_never_rewrites("review", REVIEW_DAILY_NOTES);
    assert!(
        bullets[0].starts_with("- Never rewrite, reorder, delete, summarise"),
        "the never-rewrite ground rule is still the first bullet: {bullets:?}"
    );
}

#[test]
fn review_step_one_empty_list_line_still_stops_but_reads_as_the_run_ending_after_the_feedback_work()
{
    let step = wi257_step_one();
    // Still a stop, still keyed on "no unreviewed days".
    assert_contains_ci("review step 1", &step, "no unreviewed days");
    assert_matches("review step 1", &step, r"(?i)\bstop\b");
    // Not the unconditional old line, which ended a run that had done Feedback work.
    assert!(
        !step.contains("say so in one line and stop."),
        "step 1's empty-list line must not stop before the Feedback work is reported:\n{step}"
    );
    // The stop is tied to the Feedback section's work, which is reported too.
    assert_contains("review step 1", &step, "Feedback");
    assert_matches(
        "review step 1",
        &step,
        r"(?is)\bempty\b[^.]{0,200}\b(report\w*|say\w*|reply\w*)\b[^.]{0,160}\bFeedback\b|\bFeedback\b[^.]{0,160}\b(report\w*)\b",
    );
    // The rest of step 1 is as it was.
    assert_contains("review step 1", &step, &code("list_unreviewed_days"));
    assert_contains_ci("review step 1", &step, "oldest");
}

#[test]
fn review_prompt_spells_the_feedback_glossary_terms_as_glossary_md_does_and_names_no_system_tag() {
    let text = REVIEW_DAILY_NOTES;
    let section = wi257_feedback_section();
    for term in [
        "Feedback",
        "Correction",
        "Vault Guide",
        "Handled",
        "Smart Folder",
    ] {
        assert_contains("review Feedback section", &section, term);
    }
    for (what, pattern) in [
        ("Vault Guide", r"(?i)\bvault guide\b"),
        ("Feedback", r"(?i)\bfeedback\b"),
        ("Correction", r"(?i)\bcorrections?\b"),
    ] {
        let re = Regex::new(pattern).unwrap();
        for m in re.find_iter(text) {
            assert!(
                m.as_str().starts_with(what),
                "the review prompt must spell the glossary term {what:?}, not {:?}",
                m.as_str()
            );
        }
    }
    // `organizational` is the glossary's own word; the prompt says "framework".
    assert_contains_ci("review Feedback section", &section, "framework");
    let avoid = Regex::new(
        r"(?i)\binbox\b|agent-authored|organi[sz]\w*|\b(journal|day page|snippet)\b|\b(rating|override|undo|guidelines?|memory|CLAUDE\.md)\b",
    )
    .unwrap();
    let bad: Vec<&str> = avoid.find_iter(text).map(|m| m.as_str()).collect();
    assert!(
        bad.is_empty(),
        "the review prompt uses an avoided term or names a system tag: {bad:?}"
    );
    assert_only_spec_identifiers("review", text);
}

#[test]
fn capture_opening_reads_the_vault_guide_at_session_start_follows_it_when_filing_and_does_not_write_it(
) {
    let opening = wi257_capture_opening();
    assert_contains("capture opening", &opening, "Vault Guide");
    assert_contains("capture opening", &opening, &code("get_vault_guide"));
    assert_matches(
        "capture opening",
        &opening,
        r"(?is)(start|beginning)\b[^.]{0,30}\bsession\b|\bsession (start|begins?)\b|\bbefore the first (message|observation)\b",
    );
    assert_matches(
        "capture opening",
        &opening,
        r"(?is)\bfollow\w*\b[^.]{0,120}\bfil(e|ing)\b|\bfil(e|ing)\b[^.]{0,120}\bfollow\w*\b",
    );
    // Do not write the guide.
    assert_matches(
        "capture opening",
        &opening,
        r"(?is)\b(do not|don't|never)\b[^.]{0,60}\b(write|rewrite|edit|change|update)\w*\b[^.]{0,40}\b(Vault Guide|guide)\b",
    );
    // The guide is read before the first thing capture does.
    let guide = CAPTURE.find(&code("get_vault_guide")).unwrap();
    let append = CAPTURE.find(&code("append_to_daily_note")).unwrap();
    assert!(
        guide < append,
        "the guide is read before any append:\n{CAPTURE}"
    );
}

#[test]
fn capture_prompt_leaves_feedback_to_review_and_never_tells_the_agent_to_write_the_guide() {
    for tool in ["list_open_feedback", "resolve_feedback", "record_feedback"] {
        assert!(
            !CAPTURE.contains(&code(tool)),
            "capture treats each message as an observation, so it must not name `{tool}`:\n{CAPTURE}"
        );
    }
    let negation = Regex::new(r"(?i)\b(do not|don't|never|not)\b").unwrap();
    for sentence in CAPTURE.split_inclusive(['.', '\n']) {
        if sentence.contains(&code("update_vault_guide")) {
            assert!(
                negation.is_match(sentence),
                "capture names `update_vault_guide` only to say not to call it: {sentence:?}"
            );
        }
    }
    // Still observations, and still the capture rules from before this WI.
    assert_contains_ci("capture", CAPTURE, "observation");
    assert_never_rewrites("capture", CAPTURE);
    assert_contains("capture", CAPTURE, &code("get_vault_guide"));
    assert_only_spec_identifiers("capture", CAPTURE);
}

#[test]
fn review_prompt_over_mcp_is_the_same_text_as_memex_prompt_review_and_carries_the_feedback_section()
{
    let (_dir, vault) = served_vault();
    let mut server = Server::start(&vault);
    let resp = server.get_prompt("review_daily_notes");
    let mcp = resp["result"]["messages"][0]["content"]["text"]
        .as_str()
        .unwrap_or_else(|| panic!("review_daily_notes text: {resp}"))
        .to_string();

    let cwd = tempfile::tempdir().unwrap();
    let out = Command::new(env!("CARGO_BIN_EXE_memex"))
        .args(["prompt", "review"])
        .current_dir(cwd.path())
        .stdin(Stdio::null())
        .output()
        .expect("run memex prompt review");
    assert!(out.status.success(), "memex prompt review exits 0");
    let cli = String::from_utf8(out.stdout).expect("utf-8 prompt");

    assert_eq!(mcp, cli, "MCP and `memex prompt review` serve one text");
    assert_eq!(mcp, REVIEW_DAILY_NOTES);
    let step1 = mcp.find("## 1. ").expect("step 1");
    for tool in ["get_vault_guide", "list_open_feedback", "resolve_feedback"] {
        let at = mcp
            .find(&code(tool))
            .unwrap_or_else(|| panic!("the served review prompt names `{tool}`:\n{mcp}"));
        assert!(at < step1, "`{tool}` is named before step 1:\n{mcp}");
    }
    let avoid = Regex::new(r"(?i)\binbox\b|agent-authored|organi[sz]\w*").unwrap();
    assert!(!avoid.is_match(&mcp), "no avoided term in the served text");
}

#[test]
fn prompt_review_fixture_is_the_current_prompt_and_carries_the_feedback_section() {
    let raw = wi257_repo_file("app/test/fixtures/api_v1/topics/prompt_review.json");
    let fixture: Value = serde_json::from_str(&raw).expect("the fixture is JSON");
    let text = fixture["text"].as_str().expect("a text field");
    assert_eq!(
        text, REVIEW_DAILY_NOTES,
        "re-bless prompt_review.json to the exact constant, never hand-merge it"
    );
    for tool in ["get_vault_guide", "list_open_feedback", "resolve_feedback"] {
        assert!(
            text.contains(&code(tool)),
            "the blessed prompt_review.json names `{tool}`"
        );
    }
}

// ---- WI 257 verify: contracts the implementer's handoff listed as unpinned ----

#[test]
fn review_feedback_section_updates_the_guide_with_the_fetched_version_the_whole_text_and_one_to_three_bullets_and_rereads_it_first(
) {
    let section = wi257_feedback_section();
    // The update call carries the version read with the guide, the whole new text and the bullets.
    assert_matches(
        "review Feedback section",
        &section,
        r"(?is)`update_vault_guide`[^.]{0,80}`version`[^.]{0,80}`get_vault_guide`",
    );
    assert_matches(
        "review Feedback section",
        &section,
        r"(?is)\bwhole\b[^.]{0,20}`content_md`",
    );
    assert_matches(
        "review Feedback section",
        &section,
        r"(?is)\b1 to 3\b[^.]{0,20}`bullets`",
    );
    // A second update in one pass starts from a fresh read, not the stale version.
    assert_matches(
        "review Feedback section",
        &section,
        r"(?is)\bRead the guide again\b[^.]{0,40}\bbefore the next update\b",
    );
}

#[test]
fn review_feedback_section_locates_blocks_with_get_day_filing_by_date_and_keeps_every_step_cross_reference_to_step_six(
) {
    let section = wi257_feedback_section();
    assert_matches(
        "review Feedback section",
        &section,
        r"(?is)`get_day_filing`[^.]{0,40}`date`[^.]{0,80}\bblocks\b[^.]{0,30}\bfiled\b",
    );
    // The pinned rules the filing fix respects are step 6's.
    assert_matches(
        "review Feedback section",
        &section,
        r"(?is)\bpinned rules of step 6\b",
    );
    assert_matches(
        "review Feedback section",
        &section,
        r"(?is)`add_to_smart_folder`[^.]{0,20}\bas step 6 says\b",
    );
    // The heading the cross-reference points at exists, so the reference is not dangling.
    assert!(
        wi257_review_headings()
            .iter()
            .any(|h| h == "6. Link topic notes and place them in Smart Folders"),
        "step 6 keeps its heading"
    );
}

#[test]
fn review_feedback_section_lists_one_changes_entry_for_each_note_a_fix_touched_in_both_feedback_tools(
) {
    let section = wi257_feedback_section();
    assert_matches(
        "review Feedback section",
        &section,
        r"(?is)`record_feedback`\s+or\s+`resolve_feedback`[^.]{0,60}\bone entry for each note you touched\b",
    );
    // `resolve_feedback` itself also takes the `changes` it made.
    assert_matches(
        "review Feedback section",
        &section,
        r"(?is)`resolve_feedback`,\s+passing its `id`,[^.]{0,120}`changes`",
    );
}

#[test]
fn review_step_one_report_names_the_feedback_worked_and_that_there_were_no_days_in_one_line() {
    let step = wi257_step_one();
    assert_matches(
        "review step 1",
        &step,
        r"(?is)report the Feedback you worked through,\s+and that there were no days to review,\s+in one line,\s+then stop",
    );
    // The non-empty branch is untouched: oldest date, oldest first.
    assert_matches(
        "review step 1",
        &step,
        r"(?is)\bOtherwise take the oldest date\b[^.]{0,60}\boldest first\b",
    );
}

#[test]
fn review_feedback_section_forbids_re_adding_a_topic_note_to_a_smart_folder_the_person_took_it_out_of_and_calls_it_judgment(
) {
    let section = wi257_feedback_section();
    assert_matches(
        "review Feedback section",
        &section,
        r"(?is)Never re-add a topic note to a Smart Folder that the person took it out of",
    );
    assert_matches(
        "review Feedback section",
        &section,
        r"(?is)\bno server block\b[^.]{0,40}\bjudgment\b",
    );
}
