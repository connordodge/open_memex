//! The agent activity summary builder (Spec #390 reqs 8-10, WI #450): the
//! one-line summary of an MCP write call, or nothing. Every test builds the
//! params, pre-snapshot and result JSON by hand, with the real key names of
//! each tool's `*Params` struct and result envelope (and the new req 8 fields
//! #449 adds), so nothing here needs a vault or a server.

use std::collections::{BTreeSet, HashMap};

use memex_mcp::activity_summary::{summarize, PreSnapshot, Summary, TitleLookup, WRITE_TOOLS};
use serde_json::{json, Value};

/// The 24 write tools of Spec #390 req 8, written out here so the builder's
/// own list is checked against the Spec and not against itself.
const EXPECTED_WRITE_TOOLS: [&str; 24] = [
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

// ---------- fixtures ----------

/// A title lookup over fixed maps.
#[derive(Default)]
struct FakeTitles {
    notes: HashMap<String, String>,
    folders: HashMap<String, String>,
    canvases: HashMap<String, String>,
}

impl FakeTitles {
    fn note(mut self, id: &str, title: &str) -> Self {
        self.notes.insert(id.to_string(), title.to_string());
        self
    }
    fn folder(mut self, id: &str, name: &str) -> Self {
        self.folders.insert(id.to_string(), name.to_string());
        self
    }
    fn canvas(mut self, id: &str, title: &str) -> Self {
        self.canvases.insert(id.to_string(), title.to_string());
        self
    }
}

impl TitleLookup for FakeTitles {
    fn note_title(&self, note_id: &str) -> Option<String> {
        self.notes.get(note_id).cloned()
    }
    fn folder_name(&self, folder_id: &str) -> Option<String> {
        self.folders.get(folder_id).cloned()
    }
    fn canvas_title(&self, canvas_id: &str) -> Option<String> {
        self.canvases.get(canvas_id).cloned()
    }
}

fn std_titles() -> FakeTitles {
    FakeTitles::default()
        .note("TOPIC1", "Topic Alpha")
        .note("NOTE1", "Note Beta")
        .note("FROM1", "From Note")
        .note("TO1", "To Note")
        .folder("F1", "Research")
        .canvas("C1", "Plan")
}

/// One call: its tool, params, pre-snapshot, result and title lookup.
struct Case {
    tool: String,
    params: Value,
    pre: PreSnapshot,
    result: Value,
    titles: FakeTitles,
}

impl Case {
    fn new(tool: &str, params: Value, result: Value) -> Self {
        Case {
            tool: tool.to_string(),
            params,
            pre: PreSnapshot::default(),
            result,
            titles: std_titles(),
        }
    }
    fn pre(mut self, pre: PreSnapshot) -> Self {
        self.pre = pre;
        self
    }
    fn titles(mut self, titles: FakeTitles) -> Self {
        self.titles = titles;
        self
    }
    fn set_result(mut self, key: &str, value: Value) -> Self {
        self.result[key] = value;
        self
    }
    fn drop_result(mut self, key: &str) -> Self {
        self.result.as_object_mut().unwrap().remove(key);
        self
    }
    fn set_params(mut self, key: &str, value: Value) -> Self {
        self.params[key] = value;
        self
    }
    fn drop_params(mut self, key: &str) -> Self {
        self.params.as_object_mut().unwrap().remove(key);
        self
    }
    fn run(&self) -> Option<Summary> {
        summarize(
            &self.tool,
            &self.params,
            &self.pre,
            &self.result,
            &self.titles,
        )
    }
    /// The summary, failing the test with the tool's name when there is none.
    fn summary(&self) -> Summary {
        self.run()
            .unwrap_or_else(|| panic!("{}: expected a summary, got None", self.tool))
    }
    fn text(&self) -> String {
        self.summary().text
    }
}

/// The representative successful call of each of the 24 write tools.
fn base(tool: &str) -> Case {
    match tool {
        "create_note" => Case::new(
            "create_note",
            json!({"content_md": "body", "title": "Plain Note", "tags": ["x"], "agent_id": "claude"}),
            json!({"vault_id": "V1", "note_id": "N_NEW", "version": 1}),
        ),
        "add_excerpt" => Case::new(
            tool,
            json!({"topic_note_id": "TOPIC1", "date": "2026-11-10", "block_ids": ["b1", "b2", "b3"]}),
            json!({"vault_id": "V1", "topic_note_id": "TOPIC1", "version": 4,
                   "filed_block_ids": ["b1", "b3"]}),
        ),
        "remove_excerpt" => Case::new(
            tool,
            json!({"topic_note_id": "TOPIC1", "date": "2026-11-10", "block_ids": ["b1", "b3"]}),
            json!({"vault_id": "V1", "topic_note_id": "TOPIC1", "version": 5, "removed_count": 2}),
        ),
        "remove_excerpt_block" => Case::new(
            tool,
            json!({"topic_note_id": "TOPIC1", "date": "2026-11-10", "block_id": "b2"}),
            json!({"vault_id": "V1", "topic_note_id": "TOPIC1", "version": 6, "removed": true}),
        ),
        "add_footer_topic" => Case::new(
            tool,
            json!({"note_id": "NOTE1", "topic_note_id": "TOPIC1"}),
            json!({"vault_id": "V1", "note_id": "NOTE1", "topic_note_id": "TOPIC1",
                   "origin": "excerpt", "version": 3, "changed": true}),
        ),
        "add_link" => Case::new(
            tool,
            json!({"from_id": "FROM1", "to_id": "TO1"}),
            json!({"vault_id": "V1", "link_id": "L1", "from_id": "FROM1", "to_id": "TO1",
                   "kind": "references", "source": "auto_added", "was_existing": false,
                   "note_version": 3}),
        ),
        "update_link" => Case::new(
            tool,
            json!({"link_id": "L1", "kind": "supports"}),
            json!({"vault_id": "V1", "link_id": "L1", "from_note_id": "FROM1",
                   "to_note_id": "TO1", "kind": "supports", "label": null,
                   "source": "frontmatter", "position": 0, "changed": true}),
        )
        .pre(PreSnapshot {
            link_from_title: Some("Pre From".to_string()),
            link_to_title: Some("Pre To".to_string()),
            ..PreSnapshot::default()
        })
        // The lookup is the note's title after the call: the summary must not
        // use it for update_link.
        .titles(
            FakeTitles::default()
                .note("FROM1", "Post From")
                .note("TO1", "Post To"),
        ),
        "create_smart_folder" => Case::new(
            tool,
            json!({"name": "Research"}),
            folder_json("F1", "Research", None),
        ),
        "update_smart_folder" => rename_case("New Name"),
        "delete_smart_folder" => Case::new(
            tool,
            json!({"id": "F1"}),
            json!({"vault_id": "V1", "id": "F1", "deleted": true}),
        )
        .pre(PreSnapshot {
            folder_name: Some("Doomed".to_string()),
            ..PreSnapshot::default()
        }),
        "add_to_smart_folder" => Case::new(
            tool,
            json!({"topic_note_id": "TOPIC1", "smart_folder_id": "F1"}),
            json!({"vault_id": "V1", "smart_folder_id": "F1", "note_id": "TOPIC1",
                   "pinned": false, "role_set": false, "added": true}),
        ),
        "remove_from_smart_folder" => Case::new(
            tool,
            json!({"topic_note_id": "TOPIC1", "smart_folder_id": "F1"}),
            json!({"vault_id": "V1", "smart_folder_id": "F1", "note_id": "TOPIC1",
                   "removed": true}),
        ),
        "tag_note" => Case::new(
            tool,
            json!({"note_id": "NOTE1", "tag": "#Rust"}),
            json!({"vault_id": "V1", "note_id": "NOTE1", "tag": "rust", "applied": true,
                   "version": 2}),
        ),
        "untag_note" => Case::new(
            tool,
            json!({"note_id": "NOTE1", "tag": "#Rust"}),
            json!({"vault_id": "V1", "note_id": "NOTE1", "tag": "rust", "removed": true,
                   "version": 3}),
        ),
        "append_to_daily_note" => Case::new(
            tool,
            json!({"text": "SENTINEL_BLOCK_TEXT"}),
            json!({"vault_id": "V1", "note_id": "DAILY1", "date": "2026-11-10",
                   "block_ids": ["b1", "b2"], "content_version": 7, "version": 8,
                   "prior_state": "Unreviewed"}),
        ),
        "mark_day_reviewed" => Case::new(
            tool,
            json!({"date": "2026-11-10", "version": 7,
                   "changes": [{"note_id": "DAILY1", "bullets": ["SENTINEL_BULLET"]}]}),
            json!({"vault_id": "V1", "date": "2026-11-10", "note_id": "DAILY1",
                   "state": "Reviewed", "content_version": 7, "reviewed_content_version": 7,
                   "reviewed_at": 1}),
        ),
        "create_canvas" => Case::new(
            tool,
            json!({"title": "Plan"}),
            json!({"vault_id": "V1", "canvas_id": "C1", "title": "Plan", "version": 1,
                   "created_at": 1}),
        ),
        "delete_canvas" => Case::new(
            tool,
            json!({"canvas_id": "C1", "expected_version": 2}),
            json!({"vault_id": "V1", "canvas_id": "C1"}),
        )
        .pre(PreSnapshot {
            canvas_title: Some("Old Plan".to_string()),
            ..PreSnapshot::default()
        }),
        "add_to_canvas" => Case::new(
            tool,
            json!({"canvas_id": "C1", "note_id": "NOTE1", "x": 1.0, "y": 2.0}),
            json!({"vault_id": "V1", "canvas_id": "C1", "note_id": "NOTE1",
                   "note_title": "Note Beta", "x": 1.0, "y": 2.0, "z_order": 1,
                   "placed_at": 1, "added": true}),
        ),
        "move_node" => Case::new(
            tool,
            json!({"canvas_id": "C1", "note_id": "NOTE1", "x": 5.0, "y": 6.0}),
            json!({"vault_id": "V1", "canvas_id": "C1", "note_id": "NOTE1",
                   "note_title": "Note Beta", "x": 5.0, "y": 6.0, "z_order": 1,
                   "placed_at": 1, "changed": true}),
        ),
        "remove_from_canvas" => Case::new(
            tool,
            json!({"canvas_id": "C1", "note_id": "NOTE1"}),
            json!({"vault_id": "V1", "canvas_id": "C1", "note_id": "NOTE1", "removed": true}),
        ),
        "update_vault_guide" => Case::new(
            tool,
            json!({"version": 4, "content_md": "SENTINEL_GUIDE_TEXT",
                   "bullets": ["SENTINEL_BULLET"]}),
            json!({"note_id": "GUIDE1", "version": 5}),
        ),
        "record_feedback" => Case::new(
            tool,
            json!({"text": "SENTINEL_FEEDBACK_TEXT", "note_id": "NOTE1", "date": "2026-11-10",
                   "reply": "SENTINEL_REPLY_TEXT", "changes": []}),
            feedback_row("SENTINEL_FEEDBACK_TEXT", "SENTINEL_REPLY_TEXT", "open"),
        ),
        "resolve_feedback" => Case::new(
            tool,
            json!({"id": "FB1", "reply": "SENTINEL_REPLY_TEXT",
                   "changes": [{"note_id": "NOTE1", "bullets": ["SENTINEL_BULLET"]}]}),
            feedback_row("SENTINEL_FEEDBACK_TEXT", "SENTINEL_REPLY_TEXT", "handled"),
        ),
        other => panic!("no base case for {other}"),
    }
}

fn folder_json(id: &str, name: &str, parent_id: Option<&str>) -> Value {
    json!({"vault_id": "V1", "id": id, "name": name, "parent_id": parent_id,
           "pinned": false, "depth": 1, "created_at": 1, "updated_at": 2})
}

fn feedback_row(text: &str, reply: &str, status: &str) -> Value {
    json!({"id": "FB1", "kind": "comment", "source": "chat", "note_id": "NOTE1",
           "day": "2026-11-10", "agent_change_id": null, "text": text, "correction": null,
           "status": status, "reply": reply, "created_at": 1, "updated_at": 2,
           "handled_at": null})
}

/// `update_smart_folder` renaming "Old Name" to `new_name`, parent kept (P1).
fn rename_case(new_name: &str) -> Case {
    Case::new(
        "update_smart_folder",
        json!({"id": "F1", "name": new_name}),
        folder_json("F1", new_name, Some("P1")).tap_set("changed", json!(true)),
    )
    .pre(PreSnapshot {
        folder_name: Some("Old Name".to_string()),
        folder_parent: Some("P1".to_string()),
        ..PreSnapshot::default()
    })
}

/// `update_smart_folder` moving "Same Name" from `from` to `to` (`None` is
/// the top level).
fn move_case(from: Option<&str>, to: Option<&str>) -> Case {
    let params = match to {
        Some(parent) => json!({"id": "F1", "parent_id": parent}),
        None => json!({"id": "F1", "to_root": true}),
    };
    Case::new(
        "update_smart_folder",
        params,
        folder_json("F1", "Same Name", to).tap_set("changed", json!(true)),
    )
    .pre(PreSnapshot {
        folder_name: Some("Same Name".to_string()),
        folder_parent: from.map(str::to_string),
        ..PreSnapshot::default()
    })
}

/// `update_smart_folder` renaming "Old Name" to "New Name" and moving P1 to P2.
fn rename_and_move_case() -> Case {
    Case::new(
        "update_smart_folder",
        json!({"id": "F1", "name": "New Name", "parent_id": "P2"}),
        folder_json("F1", "New Name", Some("P2")).tap_set("changed", json!(true)),
    )
    .pre(PreSnapshot {
        folder_name: Some("Old Name".to_string()),
        folder_parent: Some("P1".to_string()),
        ..PreSnapshot::default()
    })
}

trait TapSet {
    fn tap_set(self, key: &str, value: Value) -> Value;
}

impl TapSet for Value {
    fn tap_set(mut self, key: &str, value: Value) -> Value {
        self[key] = value;
        self
    }
}

fn assert_summary(case: &Case, text: &str, note_id: Option<&str>) {
    let got = case.summary();
    assert_eq!(got.text, text, "{}: text", case.tool);
    assert_eq!(
        got.note_id.as_deref(),
        note_id,
        "{}: note_id of {:?}",
        case.tool,
        got.text
    );
}

/// The first `n` characters of the repeating `abcdefghij`.
fn ascii_title(n: usize) -> String {
    "abcdefghij".chars().cycle().take(n).collect()
}

// ---------- the 24 formats (req 10), with note_id (req 9) ----------

#[test]
fn write_tools_list_is_the_24_tools_of_req_8() {
    let got: BTreeSet<&str> = WRITE_TOOLS.iter().copied().collect();
    let want: BTreeSet<&str> = EXPECTED_WRITE_TOOLS.iter().copied().collect();
    assert_eq!(want.len(), 24, "the expected list has no duplicate");
    assert_eq!(got, want, "WRITE_TOOLS names exactly the 24 write tools");
}

#[test]
fn every_write_tool_summarizes_its_representative_call() {
    for tool in EXPECTED_WRITE_TOOLS {
        let got = base(tool).summary();
        assert!(!got.text.is_empty(), "{tool}: empty summary");
    }
}

#[test]
fn create_note_plain_reads_created_title() {
    assert_summary(&base("create_note"), "created Plain Note", Some("N_NEW"));
}

#[test]
fn create_note_topic_role_reads_created_topic_title() {
    let case = base("create_note")
        .set_params("role", json!("topic"))
        .set_params("title", json!("Topic T"));
    assert_summary(&case, "created topic Topic T", Some("N_NEW"));
}

#[test]
fn create_note_daily_role_reads_created_daily_date() {
    let case = Case::new(
        "create_note",
        json!({"content_md": "", "role": "daily"}),
        json!({"vault_id": "V1", "note_id": "N_DAILY", "version": 1}),
    )
    .titles(FakeTitles::default().note("N_DAILY", "2026-11-11"));
    assert_summary(&case, "created daily 2026-11-11", Some("N_DAILY"));
}

#[test]
fn create_note_daily_role_with_a_title_param_uses_it_as_the_date() {
    let case = Case::new(
        "create_note",
        json!({"content_md": "", "role": "daily", "title": "2026-11-10"}),
        json!({"vault_id": "V1", "note_id": "N_DAILY", "version": 1}),
    )
    .titles(FakeTitles::default());
    assert_summary(&case, "created daily 2026-11-10", Some("N_DAILY"));
}

#[test]
fn create_note_without_a_title_param_takes_the_title_from_the_lookup() {
    let case = base("create_note")
        .drop_params("title")
        .titles(FakeTitles::default().note("N_NEW", "Derived Title"));
    assert_summary(&case, "created Derived Title", Some("N_NEW"));
}

#[test]
fn create_note_with_a_title_param_does_not_need_the_lookup() {
    let case = base("create_note").titles(FakeTitles::default());
    assert_summary(&case, "created Plain Note", Some("N_NEW"));
}

#[test]
fn add_excerpt_counts_filed_block_ids_not_requested_block_ids() {
    // 3 blocks asked for, 2 filed: the topic already held one.
    assert_summary(
        &base("add_excerpt"),
        "filed 2 blocks → Topic Alpha",
        Some("TOPIC1"),
    );
}

#[test]
fn add_excerpt_one_block_is_singular_and_several_are_plural() {
    let one = base("add_excerpt").set_result("filed_block_ids", json!(["b1"]));
    assert_summary(&one, "filed 1 block → Topic Alpha", Some("TOPIC1"));
    let twelve: Vec<String> = (1..=12).map(|i| format!("b{i}")).collect();
    let many = base("add_excerpt").set_result("filed_block_ids", json!(twelve));
    assert_summary(&many, "filed 12 blocks → Topic Alpha", Some("TOPIC1"));
}

#[test]
fn remove_excerpt_counts_removed_count() {
    assert_summary(
        &base("remove_excerpt"),
        "unfiled 2 blocks from Topic Alpha",
        Some("TOPIC1"),
    );
}

#[test]
fn remove_excerpt_one_block_is_singular_and_several_are_plural() {
    let one = base("remove_excerpt").set_result("removed_count", json!(1));
    assert_summary(&one, "unfiled 1 block from Topic Alpha", Some("TOPIC1"));
    let many = base("remove_excerpt").set_result("removed_count", json!(12));
    assert_summary(&many, "unfiled 12 blocks from Topic Alpha", Some("TOPIC1"));
}

#[test]
fn remove_excerpt_block_reads_unfiled_one_block() {
    assert_summary(
        &base("remove_excerpt_block"),
        "unfiled 1 block from Topic Alpha",
        Some("TOPIC1"),
    );
}

#[test]
fn add_footer_topic_reads_added_topic_to_note_footer() {
    assert_summary(
        &base("add_footer_topic"),
        "added Topic Alpha to Note Beta footer",
        Some("NOTE1"),
    );
}

#[test]
fn add_link_references_kind_has_no_suffix() {
    assert_summary(
        &base("add_link"),
        "linked From Note → To Note",
        Some("FROM1"),
    );
}

#[test]
fn add_link_other_kind_ends_with_the_kind_in_parens() {
    let case = base("add_link").set_result("kind", json!("supports"));
    assert_summary(
        &case,
        "linked From Note → To Note (supports)",
        Some("FROM1"),
    );
}

#[test]
fn add_link_kind_comes_from_the_result_not_the_params() {
    // The params' kind may be absent (default `references`) or spelled
    // differently; the result's `kind` is the stored one.
    let none = base("add_link")
        .set_params("kind", json!("SUPPORTS"))
        .set_result("kind", json!("references"));
    assert_summary(&none, "linked From Note → To Note", Some("FROM1"));
    let some = base("add_link")
        .drop_params("kind")
        .set_result("kind", json!("supports"));
    assert_summary(
        &some,
        "linked From Note → To Note (supports)",
        Some("FROM1"),
    );
}

#[test]
fn update_link_takes_both_titles_from_the_pre_snapshot() {
    assert_summary(
        &base("update_link"),
        "updated link Pre From → Pre To",
        Some("FROM1"),
    );
}

#[test]
fn create_smart_folder_reads_created_folder_name() {
    assert_summary(
        &base("create_smart_folder"),
        "created folder Research",
        None,
    );
}

#[test]
fn update_smart_folder_name_only_reads_renamed_old_to_new() {
    assert_summary(
        &rename_case("New Name"),
        "renamed folder Old Name → New Name",
        None,
    );
}

#[test]
fn update_smart_folder_parent_only_reads_moved_folder_name() {
    assert_summary(
        &move_case(Some("P1"), Some("P2")),
        "moved folder Same Name",
        None,
    );
}

#[test]
fn update_smart_folder_to_the_top_level_reads_moved() {
    assert_summary(&move_case(Some("P1"), None), "moved folder Same Name", None);
}

#[test]
fn update_smart_folder_from_the_top_level_into_a_parent_reads_moved() {
    assert_summary(&move_case(None, Some("P2")), "moved folder Same Name", None);
}

#[test]
fn update_smart_folder_name_and_parent_reads_renamed_and_moved() {
    assert_summary(
        &rename_and_move_case(),
        "renamed and moved folder Old Name → New Name",
        None,
    );
}

#[test]
fn delete_smart_folder_reads_deleted_folder_from_the_pre_snapshot() {
    // The lookup still answers F1 = "Research" (as a stale cache could): the
    // name must come from the pre-snapshot.
    assert_summary(&base("delete_smart_folder"), "deleted folder Doomed", None);
}

#[test]
fn add_to_smart_folder_reads_added_topic_to_folder() {
    assert_summary(
        &base("add_to_smart_folder"),
        "added Topic Alpha to Research",
        Some("TOPIC1"),
    );
}

#[test]
fn remove_from_smart_folder_reads_removed_topic_from_folder() {
    assert_summary(
        &base("remove_from_smart_folder"),
        "removed Topic Alpha from Research",
        Some("TOPIC1"),
    );
}

#[test]
fn tag_note_reads_tagged_note_hash_tag_with_the_stored_tag_name() {
    // The param is `#Rust`; the result's `tag` is the stored, normalized name.
    assert_summary(&base("tag_note"), "tagged Note Beta #rust", Some("NOTE1"));
}

#[test]
fn untag_note_reads_untagged_note_hash_tag() {
    assert_summary(
        &base("untag_note"),
        "untagged Note Beta #rust",
        Some("NOTE1"),
    );
}

#[test]
fn append_to_daily_note_counts_result_block_ids_on_the_result_date() {
    assert_summary(
        &base("append_to_daily_note"),
        "captured 2 blocks on 2026-11-10",
        Some("DAILY1"),
    );
}

#[test]
fn append_to_daily_note_one_block_is_singular_and_several_are_plural() {
    let one = base("append_to_daily_note").set_result("block_ids", json!(["b1"]));
    assert_summary(&one, "captured 1 block on 2026-11-10", Some("DAILY1"));
    let many = base("append_to_daily_note").set_result("block_ids", json!(["a", "b", "c"]));
    assert_summary(&many, "captured 3 blocks on 2026-11-10", Some("DAILY1"));
}

#[test]
fn append_to_daily_note_without_a_named_note_has_no_note_id() {
    let case = base("append_to_daily_note").drop_result("note_id");
    assert_summary(&case, "captured 2 blocks on 2026-11-10", None);
}

#[test]
fn mark_day_reviewed_reads_marked_date_reviewed() {
    assert_summary(
        &base("mark_day_reviewed"),
        "marked 2026-11-10 reviewed",
        Some("DAILY1"),
    );
}

#[test]
fn mark_day_reviewed_without_a_named_note_has_no_note_id() {
    let case = base("mark_day_reviewed").drop_result("note_id");
    assert_summary(&case, "marked 2026-11-10 reviewed", None);
}

#[test]
fn create_canvas_reads_created_canvas_title() {
    assert_summary(&base("create_canvas"), "created canvas Plan", None);
}

#[test]
fn delete_canvas_reads_deleted_canvas_from_the_pre_snapshot() {
    // The lookup still answers C1 = "Plan": the title must come from the
    // pre-snapshot.
    assert_summary(&base("delete_canvas"), "deleted canvas Old Plan", None);
}

#[test]
fn add_to_canvas_reads_placed_note_on_canvas() {
    assert_summary(
        &base("add_to_canvas"),
        "placed Note Beta on Plan",
        Some("NOTE1"),
    );
}

#[test]
fn move_node_reads_moved_note_on_canvas() {
    assert_summary(&base("move_node"), "moved Note Beta on Plan", Some("NOTE1"));
}

#[test]
fn remove_from_canvas_reads_removed_note_from_canvas() {
    assert_summary(
        &base("remove_from_canvas"),
        "removed Note Beta from Plan",
        Some("NOTE1"),
    );
}

#[test]
fn update_vault_guide_reads_updated_vault_guide_with_no_note_id() {
    assert_summary(&base("update_vault_guide"), "updated Vault Guide", None);
}

#[test]
fn record_feedback_reads_recorded_feedback_with_no_note_id() {
    // Both the params and the Feedback row name NOTE1: still no note_id.
    assert_summary(&base("record_feedback"), "recorded feedback", None);
}

#[test]
fn resolve_feedback_reads_resolved_feedback_with_no_note_id() {
    assert_summary(&base("resolve_feedback"), "resolved feedback", None);
}

#[test]
fn note_id_follows_the_ruling_for_every_write_tool() {
    let want: [(&str, Option<&str>); 24] = [
        ("create_note", Some("N_NEW")),
        ("add_excerpt", Some("TOPIC1")),
        ("remove_excerpt", Some("TOPIC1")),
        ("remove_excerpt_block", Some("TOPIC1")),
        ("add_footer_topic", Some("NOTE1")),
        ("add_link", Some("FROM1")),
        ("update_link", Some("FROM1")),
        ("create_smart_folder", None),
        ("update_smart_folder", None),
        ("delete_smart_folder", None),
        ("add_to_smart_folder", Some("TOPIC1")),
        ("remove_from_smart_folder", Some("TOPIC1")),
        ("tag_note", Some("NOTE1")),
        ("untag_note", Some("NOTE1")),
        ("append_to_daily_note", Some("DAILY1")),
        ("mark_day_reviewed", Some("DAILY1")),
        ("create_canvas", None),
        ("delete_canvas", None),
        ("add_to_canvas", Some("NOTE1")),
        ("move_node", Some("NOTE1")),
        ("remove_from_canvas", Some("NOTE1")),
        ("update_vault_guide", None),
        ("record_feedback", None),
        ("resolve_feedback", None),
    ];
    for (tool, note_id) in want {
        let got = base(tool).summary();
        assert_eq!(got.note_id.as_deref(), note_id, "{tool}: note_id");
    }
}

// ---------- titles and names: 40-char cut, newlines ----------

/// A place a title or name enters a summary, built around one title string.
struct Slot {
    label: &'static str,
    build: fn(&str) -> Case,
    /// The summary with `{}` where the (cut) title lands.
    template: &'static str,
}

fn slots() -> Vec<Slot> {
    fn set_note(c: Case, id: &str, title: &str) -> Case {
        let mut c = c;
        c.titles.notes.insert(id.to_string(), title.to_string());
        c
    }
    fn set_folder(c: Case, id: &str, name: &str) -> Case {
        let mut c = c;
        c.titles.folders.insert(id.to_string(), name.to_string());
        c
    }
    fn set_canvas(c: Case, id: &str, title: &str) -> Case {
        let mut c = c;
        c.titles.canvases.insert(id.to_string(), title.to_string());
        c
    }
    vec![
        Slot {
            label: "create_note title param",
            build: |t| base("create_note").set_params("title", json!(t)),
            template: "created {}",
        },
        Slot {
            label: "create_note lookup title",
            build: |t| {
                base("create_note")
                    .drop_params("title")
                    .titles(FakeTitles::default().note("N_NEW", t))
            },
            template: "created {}",
        },
        Slot {
            label: "add_excerpt topic",
            build: |t| set_note(base("add_excerpt"), "TOPIC1", t),
            template: "filed 2 blocks → {}",
        },
        Slot {
            label: "remove_excerpt topic",
            build: |t| set_note(base("remove_excerpt"), "TOPIC1", t),
            template: "unfiled 2 blocks from {}",
        },
        Slot {
            label: "remove_excerpt_block topic",
            build: |t| set_note(base("remove_excerpt_block"), "TOPIC1", t),
            template: "unfiled 1 block from {}",
        },
        Slot {
            label: "add_footer_topic topic",
            build: |t| set_note(base("add_footer_topic"), "TOPIC1", t),
            template: "added {} to Note Beta footer",
        },
        Slot {
            label: "add_footer_topic note",
            build: |t| set_note(base("add_footer_topic"), "NOTE1", t),
            template: "added Topic Alpha to {} footer",
        },
        Slot {
            label: "add_link from",
            build: |t| set_note(base("add_link"), "FROM1", t),
            template: "linked {} → To Note",
        },
        Slot {
            label: "add_link to",
            build: |t| set_note(base("add_link"), "TO1", t),
            template: "linked From Note → {}",
        },
        Slot {
            label: "update_link from (pre-snapshot)",
            build: |t| {
                let mut c = base("update_link");
                c.pre.link_from_title = Some(t.to_string());
                c
            },
            template: "updated link {} → Pre To",
        },
        Slot {
            label: "update_link to (pre-snapshot)",
            build: |t| {
                let mut c = base("update_link");
                c.pre.link_to_title = Some(t.to_string());
                c
            },
            template: "updated link Pre From → {}",
        },
        Slot {
            label: "create_smart_folder name",
            build: |t| {
                Case::new(
                    "create_smart_folder",
                    json!({"name": t}),
                    folder_json("F1", t, None),
                )
            },
            template: "created folder {}",
        },
        Slot {
            label: "update_smart_folder old name (pre-snapshot)",
            build: |t| {
                let mut c = rename_case("New Name");
                c.pre.folder_name = Some(t.to_string());
                c
            },
            template: "renamed folder {} → New Name",
        },
        Slot {
            label: "update_smart_folder new name",
            build: rename_case,
            template: "renamed folder Old Name → {}",
        },
        Slot {
            label: "update_smart_folder moved name",
            build: |t| {
                let mut c = move_case(Some("P1"), Some("P2"));
                c.pre.folder_name = Some(t.to_string());
                c.result["name"] = json!(t);
                c
            },
            template: "moved folder {}",
        },
        Slot {
            label: "delete_smart_folder name (pre-snapshot)",
            build: |t| {
                let mut c = base("delete_smart_folder");
                c.pre.folder_name = Some(t.to_string());
                c
            },
            template: "deleted folder {}",
        },
        Slot {
            label: "add_to_smart_folder topic",
            build: |t| set_note(base("add_to_smart_folder"), "TOPIC1", t),
            template: "added {} to Research",
        },
        Slot {
            label: "add_to_smart_folder folder",
            build: |t| set_folder(base("add_to_smart_folder"), "F1", t),
            template: "added Topic Alpha to {}",
        },
        Slot {
            label: "remove_from_smart_folder topic",
            build: |t| set_note(base("remove_from_smart_folder"), "TOPIC1", t),
            template: "removed {} from Research",
        },
        Slot {
            label: "remove_from_smart_folder folder",
            build: |t| set_folder(base("remove_from_smart_folder"), "F1", t),
            template: "removed Topic Alpha from {}",
        },
        Slot {
            label: "tag_note note",
            build: |t| set_note(base("tag_note"), "NOTE1", t),
            template: "tagged {} #rust",
        },
        Slot {
            label: "untag_note note",
            build: |t| set_note(base("untag_note"), "NOTE1", t),
            template: "untagged {} #rust",
        },
        Slot {
            label: "create_canvas title",
            build: |t| {
                Case::new(
                    "create_canvas",
                    json!({"title": t}),
                    json!({"vault_id": "V1", "canvas_id": "C1", "title": t, "version": 1,
                           "created_at": 1}),
                )
            },
            template: "created canvas {}",
        },
        Slot {
            label: "delete_canvas title (pre-snapshot)",
            build: |t| {
                let mut c = base("delete_canvas");
                c.pre.canvas_title = Some(t.to_string());
                c
            },
            template: "deleted canvas {}",
        },
        Slot {
            label: "add_to_canvas note title (result)",
            build: |t| base("add_to_canvas").set_result("note_title", json!(t)),
            template: "placed {} on Plan",
        },
        Slot {
            label: "add_to_canvas canvas",
            build: |t| set_canvas(base("add_to_canvas"), "C1", t),
            template: "placed Note Beta on {}",
        },
        Slot {
            label: "move_node note title (result)",
            build: |t| base("move_node").set_result("note_title", json!(t)),
            template: "moved {} on Plan",
        },
        Slot {
            label: "move_node canvas",
            build: |t| set_canvas(base("move_node"), "C1", t),
            template: "moved Note Beta on {}",
        },
        Slot {
            label: "remove_from_canvas note",
            build: |t| set_note(base("remove_from_canvas"), "NOTE1", t),
            template: "removed {} from Plan",
        },
        Slot {
            label: "remove_from_canvas canvas",
            build: |t| set_canvas(base("remove_from_canvas"), "C1", t),
            template: "removed Note Beta from {}",
        },
    ]
}

fn assert_slot(slot: &Slot, title: &str, shown: &str) {
    let case = (slot.build)(title);
    let want = slot.template.replace("{}", shown);
    assert_eq!(case.text(), want, "{}: title {title:?}", slot.label);
}

#[test]
fn a_40_char_title_appears_unchanged_everywhere() {
    for slot in slots() {
        let title = ascii_title(40);
        assert_slot(&slot, &title, &title);
    }
}

#[test]
fn a_39_char_title_appears_unchanged_everywhere() {
    for slot in slots() {
        let title = ascii_title(39);
        assert_slot(&slot, &title, &title);
    }
}

#[test]
fn a_41_char_title_is_cut_to_39_chars_plus_an_ellipsis_everywhere() {
    for slot in slots() {
        let title = ascii_title(41);
        let shown = format!("{}…", ascii_title(39));
        assert_eq!(shown.chars().count(), 40);
        assert_slot(&slot, &title, &shown);
    }
}

#[test]
fn a_long_title_is_cut_to_39_chars_plus_an_ellipsis() {
    for slot in slots() {
        let title = ascii_title(300);
        let shown = format!("{}…", ascii_title(39));
        assert_slot(&slot, &title, &shown);
    }
}

#[test]
fn a_multibyte_title_is_cut_on_char_boundaries_without_panicking() {
    // 2-byte, 3-byte and 4-byte chars, and one mixed title whose byte 39 falls
    // inside a char.
    let inputs: [(String, String); 4] = [
        ("é".repeat(41), format!("{}…", "é".repeat(39))),
        ("日".repeat(41), format!("{}…", "日".repeat(39))),
        ("😀".repeat(41), format!("{}…", "😀".repeat(39))),
        (
            format!("a{}", "é".repeat(40)),
            format!("a{}…", "é".repeat(38)),
        ),
    ];
    for slot in slots() {
        for (title, shown) in &inputs {
            assert_slot(&slot, title, shown);
        }
    }
}

#[test]
fn a_40_char_multibyte_title_is_unchanged() {
    // 40 chars but 80 bytes: the limit counts chars.
    for slot in slots() {
        let title = "é".repeat(40);
        assert_slot(&slot, &title, &title);
    }
}

#[test]
fn newlines_and_tabs_in_a_name_become_spaces() {
    for slot in slots() {
        let case = (slot.build)("line1\nline2\tend");
        let got = case.text();
        assert_eq!(
            got,
            slot.template.replace("{}", "line1 line2 end"),
            "{}",
            slot.label
        );
        assert!(!got.contains('\n') && !got.contains('\t'), "{}", slot.label);
    }
}

#[test]
fn a_name_with_several_line_breaks_stays_one_line() {
    for slot in slots() {
        let got = (slot.build)("a\n\nb\t\tc\nd").text();
        assert!(
            !got.contains('\n') && !got.contains('\t'),
            "{}: {got:?}",
            slot.label
        );
        assert_eq!(
            got,
            slot.template.replace("{}", "a  b  c d"),
            "{}",
            slot.label
        );
    }
}

// ---------- the 120-char line ----------

/// `add_link` between two 40-char notes with a kind of `kind_len` chars: the
/// summary is `93 + kind_len` chars before the whole-line cut.
fn long_link_case(from: &str, to: &str, kind_len: usize) -> (Case, String) {
    let kind = "k".repeat(kind_len);
    let case = base("add_link")
        .set_result("kind", json!(kind))
        .titles(FakeTitles::default().note("FROM1", from).note("TO1", to));
    (case, format!("linked {from} → {to} ({kind})"))
}

#[test]
fn a_120_char_summary_is_not_cut() {
    let (case, full) = long_link_case(&"f".repeat(40), &"t".repeat(40), 27);
    assert_eq!(full.chars().count(), 120);
    assert_eq!(case.text(), full);
}

#[test]
fn a_121_char_summary_is_cut_to_119_chars_plus_an_ellipsis() {
    let (case, full) = long_link_case(&"f".repeat(40), &"t".repeat(40), 28);
    assert_eq!(full.chars().count(), 121);
    let want: String = full.chars().take(119).chain(std::iter::once('…')).collect();
    let got = case.text();
    assert_eq!(got, want);
    assert_eq!(got.chars().count(), 120);
}

#[test]
fn a_very_long_summary_is_cut_to_120_chars() {
    let (case, full) = long_link_case(&"f".repeat(40), &"t".repeat(40), 200);
    let want: String = full.chars().take(119).chain(std::iter::once('…')).collect();
    assert_eq!(case.text(), want);
}

#[test]
fn a_multibyte_summary_is_cut_at_120_chars_not_bytes() {
    let (case, full) = long_link_case(&"日".repeat(40), &"本".repeat(40), 28);
    assert_eq!(full.chars().count(), 121);
    let want: String = full.chars().take(119).chain(std::iter::once('…')).collect();
    let got = case.text();
    assert_eq!(got, want);
    assert_eq!(got.chars().count(), 120);
}

#[test]
fn a_multibyte_summary_of_120_chars_is_not_cut() {
    // 120 chars, far over 120 bytes.
    let (case, full) = long_link_case(&"日".repeat(40), &"本".repeat(40), 27);
    assert_eq!(full.chars().count(), 120);
    assert!(full.len() > 120);
    assert_eq!(case.text(), full);
}

#[test]
fn a_long_tag_is_not_cut_as_a_title_but_the_line_is_cut_at_120() {
    let tag = "x".repeat(150);
    let case = base("tag_note").set_result("tag", json!(tag));
    let full = format!("tagged Note Beta #{tag}");
    let want: String = full.chars().take(119).chain(std::iter::once('…')).collect();
    let got = case.text();
    assert_eq!(got, want);
    assert_eq!(got.chars().count(), 120);
}

#[test]
fn a_tag_that_fits_the_line_is_never_shortened_to_40_chars() {
    let tag = "x".repeat(60);
    let case = base("untag_note").set_result("tag", json!(tag));
    assert_eq!(case.text(), format!("untagged Note Beta #{tag}"));
}

#[test]
fn no_representative_summary_is_over_120_chars_or_has_a_line_break() {
    for tool in EXPECTED_WRITE_TOOLS {
        let got = base(tool).text();
        assert!(got.chars().count() <= 120, "{tool}: {got:?}");
        assert!(!got.contains(['\n', '\r', '\t']), "{tool}: {got:?}");
        assert!(!got.is_empty(), "{tool}");
    }
}

// ---------- privacy (req 10) ----------

#[test]
fn a_summary_never_contains_block_note_body_or_feedback_text() {
    // Each case carries a sentinel in its params and/or result; the summary
    // must exist and must not repeat it.
    let sentinel = "SENTINEL";
    let cases = [
        base("append_to_daily_note"),
        base("create_note").set_params("content_md", json!("a body SENTINEL_BODY_TEXT")),
        base("create_note")
            .drop_params("title")
            .set_params("content_md", json!("# SENTINEL_BODY_TEXT\nmore"))
            .titles(FakeTitles::default().note("N_NEW", "Untitled")),
        base("record_feedback"),
        base("resolve_feedback"),
        base("update_vault_guide"),
        base("mark_day_reviewed"),
    ];
    for case in cases {
        let got = case.summary();
        assert!(
            !got.text.contains(sentinel),
            "{}: leaked text in {:?}",
            case.tool,
            got.text
        );
    }
}

#[test]
fn feedback_summaries_are_fixed_text_whatever_the_feedback_says() {
    let record = base("record_feedback").set_params("text", json!("anything at all"));
    assert_eq!(record.text(), "recorded feedback");
    let resolve = base("resolve_feedback").set_params("reply", json!("anything at all"));
    assert_eq!(resolve.text(), "resolved feedback");
    let guide = base("update_vault_guide").set_params("content_md", json!("# New guide"));
    assert_eq!(guide.text(), "updated Vault Guide");
}

// ---------- None: wrote nothing, errors, other tools ----------

#[test]
fn each_wrote_nothing_signal_gives_none() {
    let signals: [(&str, &str, Value); 14] = [
        ("add_excerpt", "filed_block_ids", json!([])),
        ("remove_excerpt", "removed_count", json!(0)),
        ("remove_excerpt_block", "removed", json!(false)),
        ("add_footer_topic", "changed", json!(false)),
        ("add_link", "was_existing", json!(true)),
        ("update_link", "changed", json!(false)),
        ("update_smart_folder", "changed", json!(false)),
        ("add_to_smart_folder", "added", json!(false)),
        ("remove_from_smart_folder", "removed", json!(false)),
        ("tag_note", "applied", json!(false)),
        ("untag_note", "removed", json!(false)),
        ("add_to_canvas", "added", json!(false)),
        ("move_node", "changed", json!(false)),
        ("remove_from_canvas", "removed", json!(false)),
    ];
    for (tool, key, value) in signals {
        // The same call with the signal not set is logged.
        assert!(base(tool).run().is_some(), "{tool}: baseline logs");
        let case = base(tool).set_result(key, value.clone());
        assert!(
            case.run().is_none(),
            "{tool}: {key} = {value} should write no entry"
        );
    }
}

#[test]
fn a_wrote_nothing_signal_of_one_tool_does_not_silence_another() {
    // `removed: false` is remove_excerpt_block's signal, not add_to_smart_folder's.
    let case = base("add_to_smart_folder").set_result("removed", json!(false));
    assert!(case.run().is_some());
    let case = base("tag_note").set_result("changed", json!(false));
    assert!(case.run().is_some());
    let case = base("add_link").set_result("applied", json!(false));
    assert!(case.run().is_some());
}

#[test]
fn the_always_writes_tools_log_without_any_signal_field() {
    // Req 8: a tool with no signal field is one that always writes. The
    // always-writes tools are logged with no signal field at all.
    for tool in [
        "create_note",
        "create_smart_folder",
        "delete_smart_folder",
        "append_to_daily_note",
        "mark_day_reviewed",
        "create_canvas",
        "delete_canvas",
        "update_vault_guide",
        "record_feedback",
        "resolve_feedback",
    ] {
        assert!(base(tool).run().is_some(), "{tool}");
    }
}

#[test]
fn a_missing_signal_field_means_the_call_wrote() {
    // "A Work Item that finds a tool can't no-op leaves its field out": an
    // absent boolean signal is not a wrote-nothing signal.
    for (tool, key) in [
        ("remove_excerpt_block", "removed"),
        ("add_footer_topic", "changed"),
        ("add_link", "was_existing"),
        ("update_link", "changed"),
        ("add_to_smart_folder", "added"),
        ("remove_from_smart_folder", "removed"),
        ("tag_note", "applied"),
        ("untag_note", "removed"),
        ("add_to_canvas", "added"),
        ("move_node", "changed"),
        ("remove_from_canvas", "removed"),
    ] {
        assert!(base(tool).run().is_some(), "{tool}: baseline logs");
        let case = base(tool).drop_result(key);
        assert!(
            case.run().is_some(),
            "{tool}: without `{key}` the call wrote"
        );
    }
}

#[test]
fn an_error_result_gives_none_for_every_write_tool() {
    let error = json!({"error": {"code": "not_found", "message": "no such note"}});
    for tool in EXPECTED_WRITE_TOOLS {
        assert!(base(tool).run().is_some(), "{tool}: baseline logs");
        let mut case = base(tool);
        case.result = error.clone();
        assert!(case.run().is_none(), "{tool}: error-only result");
    }
}

#[test]
fn a_result_with_an_error_key_beside_valid_fields_gives_none() {
    for tool in EXPECTED_WRITE_TOOLS {
        assert!(base(tool).run().is_some(), "{tool}: baseline logs");
        let case = base(tool).set_result("error", json!({"code": "internal", "message": "x"}));
        assert!(case.run().is_none(), "{tool}: error key beside fields");
    }
}

#[test]
fn an_error_that_is_a_plain_string_also_gives_none() {
    // The older `op.sub` tools answer {"error": "<code>", "message": …}.
    for tool in EXPECTED_WRITE_TOOLS {
        assert!(base(tool).run().is_some(), "{tool}: baseline logs");
        let case = base(tool)
            .set_result("error", json!("add_link.from_not_found"))
            .set_result("message", json!("no such note"));
        assert!(case.run().is_none(), "{tool}: string error");
    }
}

#[test]
fn a_read_tool_gives_none_for_the_same_inputs_a_write_tool_logs() {
    let write = base("tag_note");
    assert!(write.run().is_some(), "tag_note logs these inputs");
    for tool in [
        "search",
        "get_note",
        "neighbors",
        "list_tags",
        "list_canvases",
        "get_canvas",
        "list_smart_folders",
        "get_vault_settings",
        "get_vault_guide",
        "list_open_feedback",
        "get_day_filing",
        "list_unreviewed_days",
        "get_daily_note_changes",
    ] {
        let mut case = base("tag_note");
        case.tool = tool.to_string();
        assert!(case.run().is_none(), "{tool}: a read tool logs nothing");
    }
}

#[test]
fn an_unknown_tool_or_a_near_miss_name_gives_none() {
    assert!(base("tag_note").run().is_some(), "baseline logs");
    for tool in [
        "",
        "tag_notes",
        "Tag_Note",
        "tag_note ",
        "tag",
        "not_a_tool",
    ] {
        let mut case = base("tag_note");
        case.tool = tool.to_string();
        assert!(case.run().is_none(), "{tool:?}");
    }
}

// ---------- names from the pre-snapshot, not the result ----------

#[test]
fn update_link_names_come_from_the_pre_snapshot_not_the_lookup() {
    let case = base("update_link").titles(
        FakeTitles::default()
            .note("FROM1", "Looked Up From")
            .note("TO1", "Looked Up To"),
    );
    assert_eq!(case.text(), "updated link Pre From → Pre To");
}

#[test]
fn folder_rename_old_name_comes_from_the_pre_snapshot() {
    // The result and the lookup know only the new name.
    let case = rename_case("New Name").titles(FakeTitles::default().folder("F1", "New Name"));
    assert_eq!(case.text(), "renamed folder Old Name → New Name");
}

#[test]
fn folder_rename_is_told_from_a_move_by_the_pre_snapshot() {
    // Same result, different pre-snapshot: the old name tells rename from move,
    // the old parent tells move from rename.
    let renamed = rename_case("New Name");
    assert_eq!(renamed.text(), "renamed folder Old Name → New Name");
    let mut moved = rename_case("New Name");
    moved.pre.folder_name = Some("New Name".to_string());
    moved.pre.folder_parent = Some("P0".to_string());
    moved.result["parent_id"] = json!("P1");
    assert_eq!(moved.text(), "moved folder New Name");
}

#[test]
fn delete_names_come_from_the_pre_snapshot_when_the_lookup_has_nothing() {
    let folder = base("delete_smart_folder").titles(FakeTitles::default());
    assert_eq!(folder.text(), "deleted folder Doomed");
    let canvas = base("delete_canvas").titles(FakeTitles::default());
    assert_eq!(canvas.text(), "deleted canvas Old Plan");
}

// ---------- fallbacks when a source has no answer (verify-mode pins) ----------

#[test]
fn a_lookup_miss_reads_unknown_for_a_note_a_folder_and_a_canvas() {
    // The note, folder or canvas is gone by the time the summary is built.
    let none = FakeTitles::default;
    assert_eq!(
        base("add_excerpt").titles(none()).text(),
        "filed 2 blocks → (unknown)"
    );
    assert_eq!(
        base("add_to_smart_folder").titles(none()).text(),
        "added (unknown) to (unknown)"
    );
    assert_eq!(
        base("remove_from_canvas").titles(none()).text(),
        "removed (unknown) from (unknown)"
    );
    assert_eq!(
        base("add_link").titles(none()).text(),
        "linked (unknown) → (unknown)"
    );
    // Only the canvas is missing: the note keeps its title.
    let case = base("add_to_canvas").titles(FakeTitles::default().note("NOTE1", "Note Beta"));
    assert_eq!(case.text(), "placed Note Beta on (unknown)");
    // Only the folder is missing.
    let case = base("remove_from_smart_folder").titles(FakeTitles::default().note("TOPIC1", "T"));
    assert_eq!(case.text(), "removed T from (unknown)");
}

#[test]
fn a_param_naming_no_id_reads_unknown() {
    let case = base("add_excerpt").drop_params("topic_note_id");
    assert_summary(&case, "filed 2 blocks → (unknown)", None);
    let case = base("add_to_smart_folder").drop_params("smart_folder_id");
    assert_summary(&case, "added Topic Alpha to (unknown)", Some("TOPIC1"));
    let case = base("remove_from_canvas").drop_params("canvas_id");
    assert_summary(&case, "removed Note Beta from (unknown)", Some("NOTE1"));
}

#[test]
fn a_missing_title_name_or_pre_snapshot_reads_unknown() {
    let case = base("create_smart_folder").drop_result("name");
    assert_summary(&case, "created folder (unknown)", None);
    let case = base("create_canvas").drop_result("title");
    assert_summary(&case, "created canvas (unknown)", None);
    let case = base("delete_smart_folder").pre(PreSnapshot::default());
    assert_summary(&case, "deleted folder (unknown)", None);
    let case = base("delete_canvas").pre(PreSnapshot::default());
    assert_summary(&case, "deleted canvas (unknown)", None);
    let case = base("update_link").pre(PreSnapshot::default());
    assert_summary(&case, "updated link (unknown) → (unknown)", Some("FROM1"));
    let case = base("update_link").pre(PreSnapshot {
        link_from_title: Some("Only From".to_string()),
        ..PreSnapshot::default()
    });
    assert_summary(&case, "updated link Only From → (unknown)", Some("FROM1"));
    let case = base("update_link").pre(PreSnapshot {
        link_to_title: Some("Only To".to_string()),
        ..PreSnapshot::default()
    });
    assert_summary(&case, "updated link (unknown) → Only To", Some("FROM1"));
}

#[test]
fn create_note_with_neither_a_title_param_nor_a_lookup_hit_reads_unknown() {
    let case = base("create_note")
        .drop_params("title")
        .titles(FakeTitles::default());
    assert_summary(&case, "created (unknown)", Some("N_NEW"));
    let case = base("create_note")
        .drop_params("title")
        .drop_result("note_id");
    assert_summary(&case, "created (unknown)", None);
}

#[test]
fn create_note_with_an_unrecognised_or_missing_role_reads_plain_created() {
    for role in [json!("note"), json!("Topic"), json!("dailies"), json!(null)] {
        let case = base("create_note").set_params("role", role.clone());
        assert_summary(&case, "created Plain Note", Some("N_NEW"));
    }
    let case = base("create_note").drop_params("role");
    assert_summary(&case, "created Plain Note", Some("N_NEW"));
}

#[test]
fn a_carriage_return_in_a_name_becomes_a_space() {
    for slot in slots() {
        let got = (slot.build)("one\rtwo\r\nthree").text();
        assert_eq!(
            got,
            slot.template.replace("{}", "one two  three"),
            "{}",
            slot.label
        );
    }
}

#[test]
fn every_control_char_and_unicode_line_separator_in_a_name_becomes_a_space() {
    // VT, FF, NUL, DEL, NEL (U+0085), LINE SEPARATOR (U+2028), PARAGRAPH
    // SEPARATOR (U+2029), each alone and between letters.
    for sep in [
        '\u{0b}', '\u{0c}', '\u{0}', '\u{7f}', '\u{85}', '\u{2028}', '\u{2029}',
    ] {
        for slot in slots() {
            let got = (slot.build)(&format!("a{sep}b")).text();
            assert_eq!(
                got,
                slot.template.replace("{}", "a b"),
                "{} with U+{:04X}",
                slot.label,
                sep as u32
            );
        }
    }
}

#[test]
fn a_printable_non_ascii_char_in_a_name_is_kept() {
    // Only control chars and the two Unicode separators become spaces: a
    // no-break space (U+00A0) and a zero-width joiner stay.
    for keep in ['\u{a0}', '\u{200d}', '\u{2027}', '\u{202a}'] {
        for slot in slots() {
            let name = format!("a{keep}b");
            let got = (slot.build)(&name).text();
            assert_eq!(got, slot.template.replace("{}", &name), "{}", slot.label);
        }
    }
}

#[test]
fn a_line_break_in_a_kind_a_tag_or_a_date_never_reaches_the_summary() {
    // Kinds and tags are not title-cut, so the whole-line pass must clean them.
    for sep in [
        '\n', '\r', '\t', '\u{0b}', '\u{0c}', '\u{85}', '\u{2028}', '\u{2029}',
    ] {
        let case = base("add_link").set_result("kind", json!(format!("a{sep}b")));
        assert_summary(&case, "linked From Note → To Note (a b)", Some("FROM1"));
        let case = base("tag_note").set_result("tag", json!(format!("a{sep}b")));
        assert_summary(&case, "tagged Note Beta #a b", Some("NOTE1"));
        let case = base("untag_note").set_result("tag", json!(format!("a{sep}b")));
        assert_summary(&case, "untagged Note Beta #a b", Some("NOTE1"));
        let case = base("mark_day_reviewed").set_result("date", json!(format!("2026-01{sep}02")));
        assert_eq!(case.text(), "marked 2026-01 02 reviewed");
    }
}

// ---------- update_smart_folder edge cases ----------

#[test]
fn update_smart_folder_that_changes_neither_name_nor_parent_still_logs() {
    // The result says `changed: true` but the pre-snapshot already matches
    // (a person's edit raced the snapshot): the write is still recorded.
    let mut case = rename_case("Old Name");
    case.result["parent_id"] = json!("P1");
    assert_eq!(case.text(), "renamed folder Old Name → Old Name");
    // Top-level folder, still top-level, same name.
    let mut case = move_case(None, None);
    case.result["name"] = json!("Same Name");
    assert_eq!(case.text(), "renamed folder Same Name → Same Name");
    // An explicit `changed: false` still writes nothing.
    let case = rename_case("Old Name").set_result("changed", json!(false));
    assert!(case.run().is_none());
}

#[test]
fn update_smart_folder_without_a_pre_snapshot_name_reads_a_rename_from_unknown() {
    let mut case = rename_case("New Name");
    case.pre.folder_name = None;
    assert_eq!(case.text(), "renamed folder (unknown) → New Name");
}

#[test]
fn update_smart_folder_without_a_result_name_reads_unknown_for_the_new_name() {
    let case = rename_case("New Name").drop_result("name");
    assert_eq!(case.text(), "renamed folder Old Name → (unknown)");
}

#[test]
fn update_smart_folder_without_a_pre_snapshot_parent_counts_a_parent_as_a_move() {
    let mut case = move_case(None, Some("P2"));
    case.pre.folder_parent = None;
    assert_eq!(case.text(), "moved folder Same Name");
}

#[test]
fn update_smart_folder_cuts_both_names_at_40_chars() {
    let old = ascii_title(41);
    let new = "n".repeat(41);
    let mut case = rename_case(&new);
    case.pre.folder_name = Some(old.clone());
    let cut_old = format!("{}…", &old[..39]);
    let cut_new = format!("{}…", &new[..39]);
    assert_eq!(case.text(), format!("renamed folder {cut_old} → {cut_new}"));
}

// ---------- tag and date fallbacks ----------

#[test]
fn a_tag_the_result_lacks_falls_back_to_the_param_without_its_hash() {
    let case = base("tag_note").drop_result("tag");
    assert_summary(&case, "tagged Note Beta #Rust", Some("NOTE1"));
    let case = base("untag_note").drop_result("tag");
    assert_summary(&case, "untagged Note Beta #Rust", Some("NOTE1"));
    let case = base("tag_note")
        .drop_result("tag")
        .set_params("tag", json!("plain"));
    assert_summary(&case, "tagged Note Beta #plain", Some("NOTE1"));
    let case = base("tag_note")
        .drop_result("tag")
        .set_params("tag", json!("a#b"));
    assert_summary(&case, "tagged Note Beta #a#b", Some("NOTE1"));
}

#[test]
fn the_result_tag_wins_over_the_param_tag() {
    let case = base("tag_note").set_params("tag", json!("#Other"));
    assert_summary(&case, "tagged Note Beta #rust", Some("NOTE1"));
}

#[test]
fn a_tag_named_by_neither_result_nor_params_reads_unknown() {
    let case = base("tag_note").drop_result("tag").drop_params("tag");
    assert_summary(&case, "tagged Note Beta #(unknown)", Some("NOTE1"));
}

#[test]
fn a_date_the_result_lacks_falls_back_to_the_param() {
    let case = base("mark_day_reviewed")
        .drop_result("date")
        .set_params("date", json!("2026-01-02"));
    assert_summary(&case, "marked 2026-01-02 reviewed", Some("DAILY1"));
    let case = base("append_to_daily_note")
        .drop_result("date")
        .set_params("date", json!("2026-01-03"));
    assert_summary(&case, "captured 2 blocks on 2026-01-03", Some("DAILY1"));
}

#[test]
fn the_result_date_wins_over_the_param_date() {
    let case = base("mark_day_reviewed").set_params("date", json!("1999-01-01"));
    assert_summary(&case, "marked 2026-11-10 reviewed", Some("DAILY1"));
    let case = base("append_to_daily_note").set_params("date", json!("1999-01-01"));
    assert_summary(&case, "captured 2 blocks on 2026-11-10", Some("DAILY1"));
}

#[test]
fn a_date_named_by_neither_result_nor_params_reads_unknown() {
    let case = base("mark_day_reviewed")
        .drop_result("date")
        .drop_params("date");
    assert_summary(&case, "marked (unknown) reviewed", Some("DAILY1"));
    let case = base("append_to_daily_note").drop_result("date");
    assert_summary(&case, "captured 2 blocks on (unknown)", Some("DAILY1"));
}

// ---------- counts, kinds and canvas titles ----------

#[test]
fn append_to_daily_note_with_no_block_ids_reads_zero_blocks() {
    let case = base("append_to_daily_note").set_result("block_ids", json!([]));
    assert_summary(&case, "captured 0 blocks on 2026-11-10", Some("DAILY1"));
    let case = base("append_to_daily_note").drop_result("block_ids");
    assert_summary(&case, "captured 0 blocks on 2026-11-10", Some("DAILY1"));
}

#[test]
fn a_missing_or_malformed_count_source_gives_none_for_the_filed_tools() {
    // The untouched calls log; only the broken count source silences them.
    assert_summary(
        &base("add_excerpt"),
        "filed 2 blocks → Topic Alpha",
        Some("TOPIC1"),
    );
    assert!(base("remove_excerpt").run().is_some());
    assert!(base("add_excerpt")
        .drop_result("filed_block_ids")
        .run()
        .is_none());
    assert!(base("add_excerpt")
        .set_result("filed_block_ids", json!("b1"))
        .run()
        .is_none());
    assert!(base("remove_excerpt")
        .drop_result("removed_count")
        .run()
        .is_none());
    assert!(base("remove_excerpt")
        .set_result("removed_count", json!("2"))
        .run()
        .is_none());
    assert!(base("remove_excerpt")
        .set_result("removed_count", json!(-1))
        .run()
        .is_none());
}

#[test]
fn add_link_with_no_kind_in_the_result_has_no_suffix() {
    let case = base("add_link").drop_result("kind");
    assert_summary(&case, "linked From Note → To Note", Some("FROM1"));
    // A param kind never shows when the result has none.
    let case = base("add_link")
        .drop_result("kind")
        .set_params("kind", json!("supports"));
    assert_summary(&case, "linked From Note → To Note", Some("FROM1"));
}

#[test]
fn a_canvas_row_title_comes_from_the_result_then_the_lookup() {
    for tool in ["add_to_canvas", "move_node"] {
        let verb = if tool == "add_to_canvas" {
            "placed"
        } else {
            "moved"
        };
        // The result's note_title beats the lookup.
        let case = base(tool).set_result("note_title", json!("Row Title"));
        assert_summary(&case, &format!("{verb} Row Title on Plan"), Some("NOTE1"));
        // Without it, the lookup answers.
        let case = base(tool).drop_result("note_title");
        assert_summary(&case, &format!("{verb} Note Beta on Plan"), Some("NOTE1"));
        // With neither, unknown.
        let case = base(tool)
            .drop_result("note_title")
            .titles(FakeTitles::default());
        assert_summary(
            &case,
            &format!("{verb} (unknown) on (unknown)"),
            Some("NOTE1"),
        );
    }
}

#[test]
fn update_link_note_id_comes_from_the_result_from_note_id() {
    let case = base("update_link").set_result("from_note_id", json!("OTHER"));
    assert_eq!(case.summary().note_id.as_deref(), Some("OTHER"));
    let case = base("update_link").drop_result("from_note_id");
    assert_eq!(case.summary().note_id, None);
}
