//! The exact MCP tool list the server exposes (WI #240, D11).
//!
//! Include it with `#[path = "support/tool_names.rs"] mod tool_names;`, as
//! `support/server.rs` is included, so no two Work Items share a
//! `tests/support/mod.rs`.
//!
//! One const list per feature, append-only: a tool WI appends its names to its
//! own block and touches nothing else, so sibling WIs never edit adjacent
//! lines. Each block is sorted by name. Tests read the list through
//! [`all_tool_names`] and [`TOOL_COUNT`] and never repeat a name or a count of
//! their own.

#![allow(dead_code)]

/// The tools the server listed before the tags and feedback features.
pub const EXISTING_TOOLS: &[&str] = &[
    "add_excerpt",
    "add_link",
    "add_to_canvas",
    "add_to_smart_folder",
    "append_to_daily_note",
    "create_canvas",
    "create_note",
    "create_smart_folder",
    "delete_canvas",
    "delete_smart_folder",
    "get_canvas",
    "get_daily_note_changes",
    "get_note",
    "get_vault_settings",
    "list_canvases",
    "list_smart_folders",
    "list_unreviewed_days",
    "mark_day_reviewed",
    "move_node",
    "neighbors",
    "remove_excerpt",
    "remove_from_canvas",
    "remove_from_smart_folder",
    "search",
    "update_link",
    "update_smart_folder",
];

/// The tag tools (#241 fills this block; owner Spec #234).
pub const TAG_TOOLS: &[&str] = &["add_footer_topic", "list_tags", "tag_note", "untag_note"];

/// The feedback tools (#254 fills this block; owner Spec #233).
pub const FEEDBACK_TOOLS: &[&str] = &[];

/// How many tools the server exposes: the sum of every block.
pub const TOOL_COUNT: usize = EXISTING_TOOLS.len() + TAG_TOOLS.len() + FEEDBACK_TOOLS.len();

/// Every tool name of every block, sorted by name.
pub fn all_tool_names() -> Vec<&'static str> {
    let mut names: Vec<&'static str> = EXISTING_TOOLS
        .iter()
        .chain(TAG_TOOLS)
        .chain(FEEDBACK_TOOLS)
        .copied()
        .collect();
    names.sort_unstable();
    names
}
