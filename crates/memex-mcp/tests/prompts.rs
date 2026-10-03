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
/// 21, 25-27, 30, 40).
const SPEC_TOOLS: &[&str] = &[
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

/// Snake_case parameter, field, prompt and error-code names the Spec and
/// CONTRACTS C1/C2 define, which a prompt may also mention.
const SPEC_FIELDS: &[&str] = &[
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

/// Any snake_case identifier in the text must be a Spec tool or field name, so
/// an agent is never told to call a tool that the Spec does not define.
fn assert_only_spec_identifiers(prompt: &str, text: &str) {
    let known: BTreeSet<&str> = SPEC_TOOLS.iter().chain(SPEC_FIELDS).copied().collect();
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

    // Glossary spellings: always `Smart Folder` and `Topics footer`.
    let smart_folder = Regex::new(r"(?i)\bsmart folders?\b").unwrap();
    let topics_footer = Regex::new(r"(?i)\btopics footer\b").unwrap();
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
        for m in topics_footer.find_iter(text) {
            assert_eq!(
                m.as_str(),
                "Topics footer",
                "the {prompt} prompt's spelling"
            );
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
