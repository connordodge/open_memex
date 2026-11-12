//! WI #400 (Spec #394 M0, ruling D11): the tool and prompt metadata table in
//! `memex_mcp::tools::meta`.
//!
//! - The registered set always comes from the composed routers
//!   (`Memex::routers()`, rmcp `list_all()`), never a hand-copied list.
//! - The 24 write tools and each group's members are hand-listed here: they
//!   are the contract (#390 requirement 8, #394 requirement 34).
//! - `Memex::new` serves exactly what `Memex::routers()` registers (D12),
//!   checked over an in-process MCP connection.

use std::collections::BTreeSet;
use std::sync::Arc;

use memex_mcp::state::AppState;
use memex_mcp::tools::meta::{self, Group};
use memex_mcp::tools::Memex;
use rmcp::ServiceExt;
use tempfile::TempDir;

/// Spec #394 requirement 34: order, id, label, members.
const GROUPS: [(&str, &str, &[&str]); 6] = [
    (
        "notes",
        "Notes and search",
        &[
            "search",
            "get_note",
            "neighbors",
            "create_note",
            "add_link",
            "update_link",
        ],
    ),
    (
        "daily",
        "Daily review",
        &[
            "list_unreviewed_days",
            "get_daily_note_changes",
            "get_day_filing",
            "append_to_daily_note",
            "add_excerpt",
            "remove_excerpt",
            "remove_excerpt_block",
            "mark_day_reviewed",
        ],
    ),
    (
        "folders",
        "Smart Folders",
        &[
            "list_smart_folders",
            "create_smart_folder",
            "update_smart_folder",
            "delete_smart_folder",
            "add_to_smart_folder",
            "remove_from_smart_folder",
        ],
    ),
    (
        "tags",
        "Tags and Note footer",
        &["list_tags", "tag_note", "untag_note", "add_footer_topic"],
    ),
    (
        "feedback",
        "Feedback and Vault Guide",
        &[
            "list_open_feedback",
            "record_feedback",
            "resolve_feedback",
            "get_vault_guide",
            "update_vault_guide",
            "get_vault_settings",
        ],
    ),
    (
        "canvas",
        "Canvases",
        &[
            "list_canvases",
            "get_canvas",
            "create_canvas",
            "add_to_canvas",
            "remove_from_canvas",
            "move_node",
            "delete_canvas",
        ],
    ),
];

/// #390 requirement 8: exactly these 24 tools write.
const WRITE_TOOLS: [&str; 24] = [
    "create_note",
    "add_excerpt",
    "remove_excerpt",
    "remove_excerpt_block",
    "add_footer_topic",
    "add_link",
    "update_link",
    "create_smart_folder",
    "update_smart_folder",
    "delete_smart_folder",
    "add_to_smart_folder",
    "remove_from_smart_folder",
    "tag_note",
    "untag_note",
    "append_to_daily_note",
    "mark_day_reviewed",
    "create_canvas",
    "delete_canvas",
    "add_to_canvas",
    "move_node",
    "remove_from_canvas",
    "update_vault_guide",
    "record_feedback",
    "resolve_feedback",
];

const PROMPTS: [&str; 2] = ["review_daily_notes", "capture"];

fn set<'a>(items: impl IntoIterator<Item = &'a str>) -> BTreeSet<String> {
    items.into_iter().map(str::to_string).collect()
}

/// Every tool name the composed tool router registers.
fn registered_tools() -> Vec<String> {
    let (tools, _) = Memex::routers();
    let names: Vec<String> = tools
        .list_all()
        .into_iter()
        .map(|t| t.name.to_string())
        .collect();
    assert!(!names.is_empty(), "Memex::routers() registers no tools");
    names
}

/// Every prompt name the composed prompt router registers.
fn registered_prompts() -> Vec<String> {
    let (_, prompts) = Memex::routers();
    let names: Vec<String> = prompts
        .list_all()
        .into_iter()
        .map(|p| p.name.to_string())
        .collect();
    assert!(!names.is_empty(), "Memex::routers() registers no prompts");
    names
}

/// The tool and prompt names `Memex::new` serves to an MCP client.
async fn served_by_memex_new() -> (BTreeSet<String>, BTreeSet<String>) {
    let dir = TempDir::new().unwrap();
    let vault = memex_core::Vault::create(dir.path()).unwrap();
    let state = Arc::new(AppState::new(vault, dir.path().to_path_buf(), None));
    let (server_io, client_io) = tokio::io::duplex(1 << 16);
    let server = tokio::spawn(async move {
        let running = Memex::new(state).serve(server_io).await.expect("serve");
        running.waiting().await.ok();
    });
    let client = ().serve(client_io).await.expect("client handshake");
    let tools = client.list_all_tools().await.expect("list tools");
    let prompts = client.list_all_prompts().await.expect("list prompts");
    client.cancel().await.ok();
    server.await.ok();
    drop(dir);
    (
        tools.iter().map(|t| t.name.to_string()).collect(),
        prompts.iter().map(|p| p.name.to_string()).collect(),
    )
}

// ---------- AC 1: one row per registered tool, no stale rows ----------

#[test]
fn every_registered_tool_has_exactly_one_meta_row() {
    let mut missing = Vec::new();
    for name in registered_tools() {
        let rows = meta::tools().iter().filter(|r| r.name == name).count();
        if rows != 1 {
            missing.push(format!("{name}: {rows} rows"));
        }
        assert_eq!(
            meta::tool(&name).map(|r| r.name),
            Some(name.as_str()),
            "meta::tool({name:?})"
        );
    }
    assert!(
        missing.is_empty(),
        "tools without exactly one row: {missing:?}"
    );
}

#[test]
fn every_meta_tool_row_names_a_registered_tool() {
    let registered = set(registered_tools().iter().map(String::as_str));
    assert!(!meta::tools().is_empty(), "meta::tools() has no rows");
    let stale: Vec<&str> = meta::tools()
        .iter()
        .map(|r| r.name)
        .filter(|n| !registered.contains(*n))
        .collect();
    assert!(
        stale.is_empty(),
        "rows naming no registered tool: {stale:?}"
    );
    assert_eq!(meta::tools().len(), registered.len(), "one row per tool");
}

#[test]
fn meta_tool_lookup_returns_the_row_and_none_for_unknown_names() {
    let search = meta::tool("search").expect("search has a row");
    assert_eq!(search.name, "search");
    assert_eq!(search.group, Group::Notes);
    assert!(!search.writes);
    let create = meta::tool("create_note").expect("create_note has a row");
    assert_eq!(create.name, "create_note");
    assert!(create.writes);
    for row in meta::tools() {
        assert_eq!(meta::tool(row.name), Some(row), "{}", row.name);
    }
    for unknown in ["", "no_such_tool", "Search", "search ", "capture"] {
        assert_eq!(meta::tool(unknown), None, "meta::tool({unknown:?})");
    }
}

// ---------- AC 2: one row per registered prompt, no stale rows ----------

#[test]
fn every_registered_prompt_has_exactly_one_meta_row() {
    let registered = registered_prompts();
    assert_eq!(set(registered.iter().map(String::as_str)), set(PROMPTS));
    for name in registered {
        let rows = meta::prompts().iter().filter(|r| r.name == name).count();
        assert_eq!(rows, 1, "{name}: rows");
        assert_eq!(
            meta::prompt(&name).map(|r| r.name),
            Some(name.as_str()),
            "meta::prompt({name:?})"
        );
    }
}

#[test]
fn every_meta_prompt_row_names_a_registered_prompt() {
    let registered = set(registered_prompts().iter().map(String::as_str));
    assert!(!meta::prompts().is_empty(), "meta::prompts() has no rows");
    for row in meta::prompts() {
        assert!(
            registered.contains(row.name),
            "stale prompt row {}",
            row.name
        );
    }
    assert_eq!(
        meta::prompts().len(),
        registered.len(),
        "one row per prompt"
    );
}

#[test]
fn meta_prompt_lookup_returns_the_row_and_none_for_unknown_names() {
    let capture = meta::prompt("capture").expect("capture has a row");
    assert_eq!(capture.name, "capture");
    for row in meta::prompts() {
        assert_eq!(meta::prompt(row.name), Some(row), "{}", row.name);
    }
    for unknown in ["", "no_such_prompt", "Capture", "search"] {
        assert_eq!(meta::prompt(unknown), None, "meta::prompt({unknown:?})");
    }
}

// ---------- AC 3: summaries are one non-empty line of <= 100 chars ----------

fn summary_problems(name: &str, summary: &str) -> Vec<String> {
    let mut out = Vec::new();
    if summary.trim().is_empty() {
        out.push(format!("{name}: empty summary"));
    }
    if summary.contains('\n') || summary.contains('\r') {
        out.push(format!("{name}: summary spans lines"));
    }
    let chars = summary.chars().count();
    if chars > 100 {
        out.push(format!("{name}: summary is {chars} chars"));
    }
    if summary.trim() != summary {
        out.push(format!("{name}: summary has outer whitespace"));
    }
    if summary.contains('`') || summary.chars().any(char::is_control) {
        out.push(format!("{name}: summary is not plain text"));
    }
    out
}

#[test]
fn every_tool_and_prompt_summary_is_one_nonempty_line_of_at_most_100_chars() {
    assert_eq!(meta::tools().len(), registered_tools().len(), "tool rows");
    assert_eq!(
        meta::prompts().len(),
        registered_prompts().len(),
        "prompt rows"
    );
    let mut problems = Vec::new();
    for row in meta::tools() {
        problems.extend(summary_problems(row.name, row.summary));
    }
    for row in meta::prompts() {
        problems.extend(summary_problems(row.name, row.summary));
    }
    assert!(problems.is_empty(), "{problems:#?}");
}

#[test]
fn tool_summaries_are_not_cut_from_the_mcp_description() {
    let (tools, prompts) = Memex::routers();
    let mut checked = 0;
    for t in tools.list_all() {
        let row = meta::tool(&t.name).unwrap_or_else(|| panic!("{} has no row", t.name));
        let description = t.description.as_deref().unwrap_or("");
        let stem = row.summary.trim_end_matches(['.', '…']);
        assert!(
            !description.starts_with(stem),
            "{}: summary {:?} is cut from the MCP description",
            t.name,
            row.summary
        );
        checked += 1;
    }
    for p in prompts.list_all() {
        let row = meta::prompt(&p.name).unwrap_or_else(|| panic!("{} has no row", p.name));
        let description = p.description.as_deref().unwrap_or("");
        let stem = row.summary.trim_end_matches(['.', '…']);
        assert!(
            !description.starts_with(stem),
            "{}: summary {:?} is cut from the MCP description",
            p.name,
            row.summary
        );
        checked += 1;
    }
    assert!(checked > 0, "nothing registered to check");
}

// ---------- AC 4: write_tools() and is_write ----------

#[test]
fn write_tools_equals_exactly_the_24_write_names() {
    let writes = meta::write_tools();
    assert_eq!(writes.len(), 24, "no duplicates, no extras: {writes:?}");
    assert_eq!(set(writes.iter().copied()), set(WRITE_TOOLS));
}

#[test]
fn is_write_is_true_for_each_write_tool_and_false_for_every_other_registered_tool() {
    let writes = set(WRITE_TOOLS);
    let mut true_count = 0;
    for name in registered_tools() {
        let expected = writes.contains(&name);
        assert_eq!(meta::is_write(&name), expected, "is_write({name:?})");
        assert_eq!(
            meta::tool(&name).map(|r| r.writes),
            Some(expected),
            "{name}: row writes"
        );
        if meta::is_write(&name) {
            true_count += 1;
        }
    }
    assert_eq!(true_count, 24, "registered write tools");
    let write_rows = meta::tools().iter().filter(|r| r.writes).count();
    assert_eq!(write_rows, 24, "rows with writes = true");
}

#[test]
fn is_write_is_false_for_unknown_names_and_prompts() {
    assert!(meta::is_write("create_note"), "create_note writes");
    assert!(
        meta::is_write("resolve_feedback"),
        "resolve_feedback writes"
    );
    assert!(!meta::is_write("search"), "search reads");
    for name in [
        "",
        "no_such_tool",
        "CREATE_NOTE",
        "create_note ",
        "capture",
        "review_daily_notes",
    ] {
        assert!(!meta::is_write(name), "is_write({name:?})");
    }
}

// ---------- AC 5: group ids, labels, order and members ----------

#[test]
fn group_ids_and_labels_are_the_six_spec_groups_in_order() {
    let got: Vec<(&str, &str)> = meta::groups().iter().map(|g| (g.id(), g.label())).collect();
    let want: Vec<(&str, &str)> = GROUPS.iter().map(|(id, label, _)| (*id, *label)).collect();
    assert_eq!(got, want);
    assert_eq!(
        meta::groups(),
        &[
            Group::Notes,
            Group::Daily,
            Group::Folders,
            Group::Tags,
            Group::Feedback,
            Group::Canvas,
        ]
    );
}

#[test]
fn each_group_holds_exactly_the_spec_members() {
    assert!(!meta::tools().is_empty(), "meta::tools() has no rows");
    let known: BTreeSet<&str> = meta::groups().iter().map(|g| g.id()).collect();
    for row in meta::tools() {
        assert!(
            known.contains(row.group.id()),
            "{}: group {:?} is not listed by meta::groups()",
            row.name,
            row.group
        );
    }
    for (id, _, members) in GROUPS {
        let got = set(meta::tools()
            .iter()
            .filter(|r| r.group.id() == id)
            .map(|r| r.name));
        assert_eq!(got, set(members.iter().copied()), "group {id}");
    }
}

// ---------- AC 6: Memex::new serves exactly routers() ----------

#[tokio::test]
async fn memex_new_serves_exactly_the_tools_and_prompts_routers_registers() {
    let (served_tools, served_prompts) = served_by_memex_new().await;
    let (tools, prompts) = Memex::routers();
    let router_tools: BTreeSet<String> = tools
        .list_all()
        .into_iter()
        .map(|t| t.name.to_string())
        .collect();
    let router_prompts: BTreeSet<String> = prompts
        .list_all()
        .into_iter()
        .map(|p| p.name.to_string())
        .collect();
    assert_eq!(router_tools, served_tools, "routers() tools vs Memex::new");
    assert_eq!(
        router_prompts, served_prompts,
        "routers() prompts vs Memex::new"
    );
    // The registered set is unchanged from main: the 37 Spec tools, 2 prompts.
    let spec_tools = set(GROUPS.iter().flat_map(|(_, _, m)| m.iter().copied()));
    assert_eq!(spec_tools.len(), 37);
    assert_eq!(served_tools, spec_tools, "served tools");
    assert_eq!(served_prompts, set(PROMPTS), "served prompts");
}
