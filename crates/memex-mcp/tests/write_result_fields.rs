//! WI #449 (Spec #390 req 8): the "wrote nothing" result fields of the MCP
//! write tools.
//!
//! | Tool | Field | Value |
//! |---|---|---|
//! | `add_excerpt` | `filed_block_ids` | the block ids actually added |
//! | `remove_excerpt` | `removed_count` | the blocks actually unfiled |
//! | `remove_excerpt_block` | `removed` | the block was unfiled |
//! | `add_footer_topic` | `changed` | false when the chip was already there |
//! | `update_link` | `changed` | false when every given value is current |
//! | `update_smart_folder` | `changed` | false when name and parent are unchanged |
//! | `add_to_smart_folder` | `added` | false when the topic was already a member |
//! | `remove_from_smart_folder` | `removed` | false when the topic wasn't a member |
//! | `add_to_canvas` | `added` | false when it returned the existing placement |
//! | `move_node` | `changed` | false when the placement didn't change |
//! | `remove_from_canvas` | `removed` | false when the note wasn't placed |
//!
//! Every field is additive: the tool's existing result keys stay. Every call
//! goes through an rmcp client over an in-process duplex, so it passes the
//! server's `call_tool` (where #390's activity log reads these fields). The
//! person's side is written through core before the first call.

use std::collections::BTreeSet;
use std::sync::Arc;

use memex_core::footer::{self, ChipOrigin};
use memex_core::indexer;
use memex_core::notes::{self, CreateNote, NoteId};
use memex_core::smart_folders as sf;
use memex_core::{Caller, Vault};
use memex_mcp::state::AppState;
use memex_mcp::tools::Memex;
use rmcp::model::CallToolRequestParams;
use rmcp::service::RunningService;
use rmcp::{RoleClient, ServiceExt};
use rusqlite::params;
use serde_json::{json, Value};
use tempfile::TempDir;
use tokio::task::JoinHandle;

const DAY: &str = "2026-09-05";
/// Three blocks, pinned by ord to [`B7`], [`C3`] and [`F6`].
const DAY_BODY: &str = "Fixed the jump arc.\n\n- tried coyote time\n\nSleep was bad.\n";
const B7: &str = "b7k2m9";
const C3: &str = "c3d4e5";
const F6: &str = "f6g7h8";

/// A vault served over an in-process rmcp duplex.
struct World {
    _dir: TempDir,
    state: Arc<AppState>,
    client: RunningService<RoleClient, ()>,
    server: JoinHandle<()>,
}

impl Drop for World {
    fn drop(&mut self) {
        self.server.abort();
    }
}

async fn world() -> World {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("vault");
    let vault = Vault::create(&path).unwrap();
    let state = Arc::new(AppState::new(vault, path, None));
    let memex = Memex::new(state.clone());
    let (server_io, client_io) = tokio::io::duplex(1 << 20);
    let server = tokio::spawn(async move {
        let running = memex.serve(server_io).await.expect("serve over duplex");
        let _ = running.waiting().await;
    });
    let client = ().serve(client_io).await.expect("client over duplex");
    World {
        _dir: dir,
        state,
        client,
        server,
    }
}

impl World {
    /// Calls `tool` through the rmcp client; its JSON payload.
    async fn call(&self, tool: &str, args: Value) -> Value {
        let Value::Object(arguments) = args else {
            panic!("tool arguments are an object");
        };
        let result = self
            .client
            .call_tool(CallToolRequestParams::new(tool.to_string()).with_arguments(arguments))
            .await
            .unwrap_or_else(|e| panic!("call {tool}: {e}"));
        let result = serde_json::to_value(result).expect("serialize CallToolResult");
        let text = result["content"][0]["text"]
            .as_str()
            .unwrap_or_else(|| panic!("{tool}: a text content: {result}"));
        serde_json::from_str(text).unwrap_or_else(|e| panic!("{tool}: not JSON ({e}): {text}"))
    }

    /// [`Self::call`], asserting the call succeeded.
    async fn ok(&self, tool: &str, args: Value) -> Value {
        let v = self.call(tool, args).await;
        assert!(v.get("error").is_none(), "{tool} failed: {v}");
        v
    }

    async fn vault_id(&self) -> String {
        self.state.vault.lock().await.vault_id().to_string()
    }

    /// The stored version of note `id`.
    async fn version(&self, id: &str) -> i64 {
        let vault = self.state.vault.lock().await;
        vault
            .connection_ref()
            .query_row("SELECT version FROM notes WHERE id = ?", [id], |r| r.get(0))
            .unwrap()
    }

    /// A note created on the person path and indexed, as the app would.
    async fn person_note(&self, title: &str, body: &str, role: Option<&str>) -> String {
        let mut vault = self.state.vault.lock().await;
        let note = notes::create_note_as(
            &mut vault,
            CreateNote {
                title: Some(title.into()),
                content_md: body.into(),
                frontmatter: role.map(|r| json!({ "role": r })),
            },
            Caller::Person,
        )
        .unwrap_or_else(|e| panic!("create {title}: {e}"));
        indexer::reindex_note(
            vault.connection_mut(),
            note.id.as_str(),
            &note.content_md,
            None,
        )
        .unwrap();
        note.id.to_string()
    }

    /// The person's daily note [`DAY`], its blocks pinned to B7, C3, F6.
    async fn day(&self) -> String {
        let day = self.person_note(DAY, DAY_BODY, Some("daily")).await;
        let vault = self.state.vault.lock().await;
        for (ord, id) in [B7, C3, F6].iter().enumerate() {
            let n = vault
                .connection_ref()
                .execute(
                    "UPDATE blocks SET block_id = ? WHERE note_id = ? AND ord = ?",
                    params![id, day, ord as i64],
                )
                .unwrap();
            assert_eq!(n, 1, "precondition: block at ord {ord}");
        }
        day
    }

    /// An agent-written note through `create_note`; its id.
    async fn agent_note(&self, title: &str, body: &str, role: Option<&str>) -> String {
        let mut args = json!({ "title": title, "content_md": body });
        if let Some(role) = role {
            args["role"] = json!(role);
        }
        let v = self.ok("create_note", args).await;
        v["note_id"].as_str().expect("note_id").to_string()
    }

    async fn add_excerpt(&self, topic: &str, ids: &[&str]) -> Value {
        self.call(
            "add_excerpt",
            json!({ "topic_note_id": topic, "date": DAY, "block_ids": ids }),
        )
        .await
    }

    async fn remove_excerpt(&self, topic: &str, ids: &[&str]) -> Value {
        self.call(
            "remove_excerpt",
            json!({ "topic_note_id": topic, "date": DAY, "block_ids": ids }),
        )
        .await
    }

    async fn remove_excerpt_block(&self, topic: &str, id: &str) -> Value {
        self.call(
            "remove_excerpt_block",
            json!({ "topic_note_id": topic, "date": DAY, "block_id": id }),
        )
        .await
    }

    async fn add_footer_topic(&self, note: &str, topic: &str) -> Value {
        self.call(
            "add_footer_topic",
            json!({ "note_id": note, "topic_note_id": topic }),
        )
        .await
    }

    /// A Smart Folder created through `create_smart_folder`; its id.
    async fn folder(&self, name: &str, parent: Option<&str>) -> String {
        let mut args = json!({ "name": name });
        if let Some(p) = parent {
            args["parent_id"] = json!(p);
        }
        let v = self.ok("create_smart_folder", args).await;
        v["id"].as_str().expect("folder id").to_string()
    }

    async fn update_folder(&self, args: Value) -> Value {
        self.call("update_smart_folder", args).await
    }

    async fn add_member(&self, folder: &str, topic: &str) -> Value {
        self.call(
            "add_to_smart_folder",
            json!({ "smart_folder_id": folder, "topic_note_id": topic }),
        )
        .await
    }

    async fn remove_member(&self, folder: &str, topic: &str) -> Value {
        self.call(
            "remove_from_smart_folder",
            json!({ "smart_folder_id": folder, "topic_note_id": topic }),
        )
        .await
    }

    /// Whether `topic` is a member of `folder`, straight from the table.
    async fn is_member(&self, folder: &str, topic: &str) -> bool {
        let vault = self.state.vault.lock().await;
        vault
            .connection_ref()
            .query_row(
                "SELECT COUNT(*) FROM smart_folder_members WHERE smart_folder_id = ? AND note_id = ?",
                params![folder, topic],
                |r| r.get::<_, i64>(0),
            )
            .unwrap()
            == 1
    }

    /// A canvas created through `create_canvas`; its id.
    async fn canvas(&self, title: &str) -> String {
        let v = self.ok("create_canvas", json!({ "title": title })).await;
        v["canvas_id"].as_str().expect("canvas_id").to_string()
    }

    async fn canvas_version(&self, canvas: &str) -> i64 {
        let vault = self.state.vault.lock().await;
        vault
            .connection_ref()
            .query_row("SELECT version FROM canvases WHERE id = ?", [canvas], |r| {
                r.get(0)
            })
            .unwrap()
    }

    async fn place(&self, canvas: &str, note: &str, x: f64, y: f64) -> Value {
        self.call(
            "add_to_canvas",
            json!({ "canvas_id": canvas, "note_id": note, "x": x, "y": y }),
        )
        .await
    }

    async fn move_node(&self, canvas: &str, note: &str, x: f64, y: f64, z: Option<i64>) -> Value {
        let mut args = json!({ "canvas_id": canvas, "note_id": note, "x": x, "y": y });
        if let Some(z) = z {
            args["z_order"] = json!(z);
        }
        self.call("move_node", args).await
    }

    async fn unplace(&self, canvas: &str, note: &str) -> Value {
        self.call(
            "remove_from_canvas",
            json!({ "canvas_id": canvas, "note_id": note }),
        )
        .await
    }

    /// An agent note `Source` whose body links `[[Target]]`; (source id, link id).
    async fn link(&self) -> (String, String) {
        self.agent_note("Target", "# Target\n", None).await;
        let source = self
            .agent_note("Source", "Hello [[Target]] world.", None)
            .await;
        let note = self
            .ok(
                "get_note",
                json!({ "note_id": source, "include_backlinks": true }),
            )
            .await;
        let link_id = note["links"]["references"][0]["link_id"]
            .as_str()
            .unwrap_or_else(|| panic!("the [[Target]] link: {note}"))
            .to_string();
        (source, link_id)
    }

    async fn update_link(&self, args: Value) -> Value {
        self.call("update_link", args).await
    }
}

fn keys(v: &Value) -> BTreeSet<String> {
    v.as_object()
        .unwrap_or_else(|| panic!("expected an object: {v}"))
        .keys()
        .cloned()
        .collect()
}

fn set(items: &[&str]) -> BTreeSet<String> {
    items.iter().map(|s| s.to_string()).collect()
}

/// Asserts the C1 error object with `code`.
fn assert_c1(v: &Value, code: &str, what: &str) {
    assert_eq!(keys(v), set(&["error"]), "{what}: only `error`: {v}");
    assert_eq!(v["error"]["code"], json!(code), "{what}: {v}");
}

// ======================================================================
// AC 1: add_excerpt returns `filed_block_ids`, the blocks it added.
// ======================================================================

#[tokio::test]
async fn add_excerpt_returns_filed_block_ids_without_the_blocks_the_topic_already_held() {
    let w = world().await;
    w.day().await;
    let topic = w
        .person_note("Player Loop", "About it.\n", Some("topic"))
        .await;
    let held = w.add_excerpt(&topic, &[B7]).await;
    assert_eq!(held["filed_block_ids"], json!([B7]), "{held}");

    let got = w.add_excerpt(&topic, &[B7, C3, F6]).await;
    assert_eq!(
        got["filed_block_ids"],
        json!([C3, F6]),
        "exactly the two blocks the topic didn't hold: {got}"
    );
    assert_eq!(got["topic_note_id"], json!(topic), "{got}");
    assert_eq!(got["version"], json!(w.version(&topic).await), "{got}");

    let version = w.version(&topic).await;
    let again = w.add_excerpt(&topic, &[B7, C3, F6]).await;
    assert_eq!(
        again["filed_block_ids"],
        json!([]),
        "a repeat files nothing: {again}"
    );
    assert_eq!(again["version"], json!(version), "{again}");
    assert_eq!(w.version(&topic).await, version, "the repeat wrote nothing");
}

#[tokio::test]
async fn add_excerpt_returns_every_block_it_files_into_an_empty_topic() {
    let w = world().await;
    w.day().await;
    let topic = w
        .person_note("Player Loop", "About it.\n", Some("topic"))
        .await;

    let got = w.add_excerpt(&topic, &[B7, C3]).await;

    assert_eq!(got["filed_block_ids"], json!([B7, C3]), "{got}");
}

#[tokio::test]
async fn add_excerpt_counts_blocks_inside_a_filed_range_as_already_held() {
    let w = world().await;
    w.day().await;
    let topic = w
        .person_note("Player Loop", "About it.\n", Some("topic"))
        .await;
    // B7 and C3 are consecutive: one range token ![[DAY#^b7k2m9..^c3d4e5]].
    w.add_excerpt(&topic, &[B7, C3]).await;

    let got = w.add_excerpt(&topic, &[C3, F6]).await;

    assert_eq!(got["filed_block_ids"], json!([F6]), "{got}");
}

#[tokio::test]
async fn add_excerpt_lists_a_repeated_block_id_once() {
    let w = world().await;
    w.day().await;
    let topic = w
        .person_note("Player Loop", "About it.\n", Some("topic"))
        .await;

    let got = w.add_excerpt(&topic, &[C3, C3]).await;

    assert_eq!(got["filed_block_ids"], json!([C3]), "{got}");
}

// ======================================================================
// AC 2: remove_excerpt returns `removed_count`, the blocks it unfiled.
// ======================================================================

#[tokio::test]
async fn remove_excerpt_returns_removed_count_equal_to_the_blocks_it_unfiled() {
    let w = world().await;
    w.day().await;
    let topic = w
        .person_note("Player Loop", "About it.\n", Some("topic"))
        .await;
    let other = w
        .person_note("Sleep", "About sleep.\n", Some("topic"))
        .await;
    // One range token covering three blocks, and one single-block token.
    w.add_excerpt(&topic, &[B7, C3, F6]).await;
    w.add_excerpt(&other, &[F6]).await;

    let range = w.remove_excerpt(&topic, &[B7, F6]).await;
    assert_eq!(
        range["removed_count"],
        json!(3),
        "the range covered three blocks, not its two endpoints: {range}"
    );
    assert_eq!(range["topic_note_id"], json!(topic), "{range}");
    assert_eq!(range["version"], json!(w.version(&topic).await), "{range}");

    let single = w.remove_excerpt(&other, &[F6]).await;
    assert_eq!(single["removed_count"], json!(1), "{single}");
}

/// Q1 (pending the lead's ruling): `remove_excerpt` can't succeed without
/// writing. A transclusion the topic doesn't hold is `not_found`, as
/// `excerpts_tools.rs` already pins, so `removed_count` is never 0.
#[tokio::test]
async fn remove_excerpt_of_blocks_not_filed_is_not_found_and_writes_nothing() {
    let w = world().await;
    w.day().await;
    let topic = w
        .person_note("Player Loop", "About it.\n", Some("topic"))
        .await;
    w.add_excerpt(&topic, &[B7]).await;
    w.ok(
        "remove_excerpt",
        json!({ "topic_note_id": topic, "date": DAY, "block_ids": [B7] }),
    )
    .await;
    let version = w.version(&topic).await;

    assert_c1(
        &w.remove_excerpt(&topic, &[B7]).await,
        "not_found",
        "a repeat",
    );
    assert_c1(
        &w.remove_excerpt(&topic, &[C3]).await,
        "not_found",
        "never filed",
    );
    assert_eq!(w.version(&topic).await, version, "nothing is written");
}

// ----------------------------------------------------------------------
// Fix round 1: the documented edges of `filed_block_ids` and `removed_count`.
// ----------------------------------------------------------------------

impl World {
    /// The stored body of note `id`.
    async fn body(&self, id: &str) -> String {
        let vault = self.state.vault.lock().await;
        vault
            .connection_ref()
            .query_row("SELECT content_md FROM notes WHERE id = ?", [id], |r| {
                r.get(0)
            })
            .unwrap()
    }

    /// The origin of the footer chip of `day` for `topic`, if there is one.
    async fn chip_origin(&self, day: &str, topic: &str) -> Option<String> {
        let vault = self.state.vault.lock().await;
        vault
            .connection_ref()
            .query_row(
                "SELECT origin FROM footer_chips WHERE daily_note_id = ? AND topic_note_id = ?",
                params![day, topic],
                |r| r.get(0),
            )
            .ok()
    }

    /// Removes the daily note `day` through core, as the person would.
    async fn remove_day(&self, day: &str) {
        let mut vault = self.state.vault.lock().await;
        let id = NoteId::parse(day).unwrap();
        let version = notes::get_note(&vault, &id).unwrap().version;
        notes::delete_note_checked(&mut vault, &id, version, None).unwrap();
    }
}

#[tokio::test]
async fn add_excerpt_lists_the_filed_blocks_in_day_order_whatever_order_the_ids_came_in() {
    let w = world().await;
    w.day().await;
    let topic = w
        .person_note("Player Loop", "About it.\n", Some("topic"))
        .await;

    // F6, C3 then B7 are given backwards; the day holds them as B7, C3, F6.
    let got = w.add_excerpt(&topic, &[F6, C3, B7]).await;

    assert_eq!(got["filed_block_ids"], json!([B7, C3, F6]), "{got}");
}

/// The tool description promises it: an empty `filed_block_ids` does not mean
/// the call wrote nothing. The topic holds every block (a token the agent
/// didn't write, here the person's), but the day has no chip for it, so the
/// call adds the chip and bumps the daily note's version. Once the chip is
/// there a repeat writes nothing at all.
#[tokio::test]
async fn add_excerpt_with_nothing_to_file_still_adds_the_days_missing_chip() {
    let w = world().await;
    let day = w.day().await;
    let topic = w
        .person_note(
            "Player Loop",
            &format!("About it.\n\n## {DAY}\n\n![[{DAY}#^{C3}]]\n"),
            Some("topic"),
        )
        .await;
    assert_eq!(w.chip_origin(&day, &topic).await, None, "precondition");
    let topic_version = w.version(&topic).await;
    let day_version = w.version(&day).await;

    let got = w.add_excerpt(&topic, &[C3]).await;

    assert_eq!(
        got["filed_block_ids"],
        json!([]),
        "the topic held it: {got}"
    );
    assert_eq!(
        w.version(&topic).await,
        topic_version,
        "the topic is untouched"
    );
    assert_eq!(got["version"], json!(topic_version), "{got}");
    assert_eq!(
        w.chip_origin(&day, &topic).await.as_deref(),
        Some("excerpt"),
        "the day's chip was added although nothing was filed"
    );
    assert!(
        w.version(&day).await > day_version,
        "the daily note was rewritten with its chip"
    );

    let day_version = w.version(&day).await;
    let again = w.add_excerpt(&topic, &[C3]).await;
    assert_eq!(again["filed_block_ids"], json!([]), "{again}");
    assert_eq!(w.version(&topic).await, topic_version);
    assert_eq!(
        w.version(&day).await,
        day_version,
        "with the chip there, the repeat writes nothing"
    );
}

/// A token whose first endpoint no longer resolves covers no stored block, so
/// the count falls back to the endpoints themselves: 2 for a range, 1 for a
/// single token. The tool description says so.
#[tokio::test]
async fn remove_excerpt_counts_the_endpoints_of_a_token_whose_endpoint_is_gone() {
    let w = world().await;
    w.day().await;
    let topic = w
        .person_note(
            "Player Loop",
            &format!("About it.\n\n## {DAY}\n\n![[{DAY}#^zzzzzz..^{C3}]]\n\n![[{DAY}#^yyyyyy]]\n"),
            Some("topic"),
        )
        .await;

    let range = w.remove_excerpt(&topic, &["zzzzzz", C3]).await;
    assert_eq!(range["removed_count"], json!(2), "{range}");
    let body = w.body(&topic).await;
    assert!(!body.contains("zzzzzz"), "the range token is gone: {body}");
    assert!(body.contains("yyyyyy"), "the other token stays: {body}");
    assert_eq!(range["version"], json!(w.version(&topic).await), "{range}");

    let single = w.remove_excerpt(&topic, &["yyyyyy"]).await;
    assert_eq!(single["removed_count"], json!(1), "{single}");
    let body = w.body(&topic).await;
    assert!(!body.contains("yyyyyy"), "the single token is gone: {body}");
}

/// The daily note was removed after the blocks were filed: the day has no
/// stored blocks, so the count is the endpoints, and the token still goes.
#[tokio::test]
async fn remove_excerpt_counts_the_endpoints_when_the_daily_note_was_removed() {
    let w = world().await;
    let day = w.day().await;
    let topic = w
        .person_note("Player Loop", "About it.\n", Some("topic"))
        .await;
    let other = w
        .person_note("Sleep", "About sleep.\n", Some("topic"))
        .await;
    w.add_excerpt(&topic, &[B7, C3, F6]).await;
    w.add_excerpt(&other, &[F6]).await;
    w.remove_day(&day).await;

    let range = w.remove_excerpt(&topic, &[B7, F6]).await;
    assert_eq!(
        range["removed_count"],
        json!(2),
        "the day's blocks are gone, so the range counts its endpoints: {range}"
    );
    assert!(
        !w.body(&topic).await.contains(&format!("^{B7}")),
        "the range token is gone"
    );

    let single = w.remove_excerpt(&other, &[F6]).await;
    assert_eq!(single["removed_count"], json!(1), "{single}");
    assert!(
        !w.body(&other).await.contains(&format!("^{F6}")),
        "the single token is gone"
    );
}

// ======================================================================
// AC 3: remove_excerpt_block returns `removed`.
// ======================================================================

#[tokio::test]
async fn remove_excerpt_block_returns_removed_true_when_it_unfiles_the_block() {
    let w = world().await;
    w.day().await;
    let topic = w
        .person_note("Player Loop", "About it.\n", Some("topic"))
        .await;
    w.add_excerpt(&topic, &[B7, C3, F6]).await;

    let got = w.remove_excerpt_block(&topic, C3).await;

    assert_eq!(got["removed"], json!(true), "{got}");
    assert_eq!(got["topic_note_id"], json!(topic), "{got}");
    assert_eq!(got["version"], json!(w.version(&topic).await), "{got}");
}

/// Q1 (pending the lead's ruling): a repeat is `not_found`, as
/// `feedback_tools.rs` already pins ("a block no token covers").
#[tokio::test]
async fn remove_excerpt_block_repeat_is_not_found_and_writes_nothing() {
    let w = world().await;
    w.day().await;
    let topic = w
        .person_note("Player Loop", "About it.\n", Some("topic"))
        .await;
    w.add_excerpt(&topic, &[B7, C3, F6]).await;
    w.ok(
        "remove_excerpt_block",
        json!({ "topic_note_id": topic, "date": DAY, "block_id": C3 }),
    )
    .await;
    let version = w.version(&topic).await;

    assert_c1(
        &w.remove_excerpt_block(&topic, C3).await,
        "not_found",
        "a repeat",
    );
    assert_eq!(w.version(&topic).await, version, "nothing is written");
}

// ======================================================================
// AC 4: add_footer_topic returns `changed`.
// ======================================================================

#[tokio::test]
async fn add_footer_topic_returns_changed_true_when_it_adds_the_chip() {
    let w = world().await;
    let topic = w
        .person_note("Player Loop", "About it.\n", Some("topic"))
        .await;
    let note = w.person_note("Plain", "Person text.\n", None).await;
    let before = w.version(&note).await;

    let got = w.add_footer_topic(&note, &topic).await;

    assert_eq!(got["changed"], json!(true), "{got}");
    assert_eq!(got["origin"], json!("excerpt"), "{got}");
    assert!(w.version(&note).await > before, "the chip was written");
}

#[tokio::test]
async fn add_footer_topic_returns_changed_false_when_the_chip_is_already_there() {
    let w = world().await;
    let topic = w
        .person_note("Player Loop", "About it.\n", Some("topic"))
        .await;
    let note = w.person_note("Plain", "Person text.\n", None).await;
    w.add_footer_topic(&note, &topic).await;
    let version = w.version(&note).await;

    let again = w.add_footer_topic(&note, &topic).await;
    assert_eq!(
        again["changed"],
        json!(false),
        "the agent's own chip: {again}"
    );
    assert_eq!(again["version"], json!(version), "{again}");

    // A chip the person added: the agent's call keeps it and writes nothing.
    let other = w.person_note("Other", "More text.\n", None).await;
    {
        let mut vault = w.state.vault.lock().await;
        footer::set_chip(
            &mut vault,
            &NoteId::parse(&other).unwrap(),
            &NoteId::parse(&topic).unwrap(),
            ChipOrigin::Person,
            None,
        )
        .unwrap();
    }
    let version = w.version(&other).await;
    let person = w.add_footer_topic(&other, &topic).await;
    assert_eq!(person["changed"], json!(false), "a person chip: {person}");
    assert_eq!(person["origin"], json!("person"), "{person}");
    assert_eq!(w.version(&other).await, version, "nothing is written");
}

// ======================================================================
// AC 5: update_link returns `changed`.
// ======================================================================

#[tokio::test]
async fn update_link_returns_changed_true_when_it_changes_the_link() {
    let w = world().await;
    let (source, first_link) = w.link().await;

    // Every save reindexes the source and gives each of its links a new id, so each
    // call below takes the id the previous result returned.
    let cases = [
        (json!({ "kind": "extends" }), "a new kind"),
        (json!({ "label": "the goal" }), "a new label"),
        (
            json!({ "kind": "contradicts", "label": "not the goal" }),
            "both",
        ),
        (json!({ "clear_label": true }), "clearing a label"),
    ];
    let mut link = first_link;
    for (mut args, what) in cases {
        args["link_id"] = json!(link);
        let before = w.version(&source).await;
        let got = w.update_link(args).await;
        assert_eq!(got["changed"], json!(true), "{what}: {got}");
        assert!(
            w.version(&source).await > before,
            "{what}: the source was saved"
        );
        link = got["link_id"]
            .as_str()
            .unwrap_or_else(|| panic!("{what}: no link_id in {got}"))
            .to_string();
    }
}

#[tokio::test]
async fn update_link_returns_changed_false_when_every_given_value_equals_the_current_one() {
    let w = world().await;
    let (source, link) = w.link().await;

    // A link with no label, kind `references`.
    let bare = [
        (json!({ "link_id": link }), "nothing given"),
        (
            json!({ "link_id": link, "kind": "references" }),
            "the current kind",
        ),
        (
            json!({ "link_id": link, "clear_label": true }),
            "clearing no label",
        ),
        (
            json!({ "link_id": link, "label": "" }),
            "an empty label on no label",
        ),
    ];
    for (args, what) in bare {
        let before = w.version(&source).await;
        let got = w.update_link(args).await;
        assert!(got.get("error").is_none(), "{what}: {got}");
        assert_eq!(got["changed"], json!(false), "{what}: {got}");
        assert_eq!(got["kind"], json!("references"), "{what}: {got}");
        assert_eq!(
            w.version(&source).await,
            before,
            "{what}: nothing is written"
        );
    }

    // The change below saves the source, which gives its links new ids.
    let set_up = w
        .update_link(json!({ "link_id": link, "kind": "extends", "label": "the goal" }))
        .await;
    assert_eq!(set_up["label"], json!("the goal"), "{set_up}");
    let link = set_up["link_id"].as_str().expect("a link_id").to_string();
    let labelled = [
        (
            json!({ "link_id": link, "kind": "extends" }),
            "the current kind",
        ),
        (
            json!({ "link_id": link, "label": "the goal" }),
            "the current label",
        ),
        (
            json!({ "link_id": link, "kind": "extends", "label": "the goal" }),
            "both current",
        ),
    ];
    for (args, what) in labelled {
        let before = w.version(&source).await;
        let got = w.update_link(args).await;
        assert_eq!(got["changed"], json!(false), "{what}: {got}");
        assert_eq!(got["label"], json!("the goal"), "{what}: {got}");
        assert_eq!(
            w.version(&source).await,
            before,
            "{what}: nothing is written"
        );
    }
}

// ======================================================================
// AC 6: update_smart_folder returns `changed`.
// ======================================================================

#[tokio::test]
async fn update_smart_folder_returns_changed_false_when_the_name_and_parent_are_unchanged() {
    let w = world().await;
    let games = w.folder("Games", None).await;
    let design = w.folder("Design", Some(&games)).await;

    let cases = [
        (json!({ "id": design }), "nothing given"),
        (
            json!({ "id": design, "name": "Design" }),
            "the current name",
        ),
        (
            json!({ "id": design, "parent_id": games }),
            "the current parent",
        ),
        (
            json!({ "id": design, "name": "Design", "parent_id": games }),
            "both current",
        ),
        (
            json!({ "id": games, "to_root": true }),
            "a root folder to the root",
        ),
    ];
    for (args, what) in cases {
        let got = w.update_folder(args).await;
        assert!(got.get("error").is_none(), "{what}: {got}");
        assert_eq!(got["changed"], json!(false), "{what}: {got}");
    }
    let got = w.update_folder(json!({ "id": design })).await;
    assert_eq!(got["name"], json!("Design"), "{got}");
    assert_eq!(got["parent_id"], json!(games), "{got}");
}

#[tokio::test]
async fn update_smart_folder_returns_changed_true_for_a_rename_a_move_and_both() {
    let w = world().await;
    let games = w.folder("Games", None).await;
    let music = w.folder("Music", None).await;
    let design = w.folder("Design", Some(&games)).await;

    let renamed = w
        .update_folder(json!({ "id": design, "name": "Game Design" }))
        .await;
    assert_eq!(renamed["changed"], json!(true), "a rename: {renamed}");
    assert_eq!(renamed["name"], json!("Game Design"), "{renamed}");

    let moved = w
        .update_folder(json!({ "id": design, "parent_id": music }))
        .await;
    assert_eq!(moved["changed"], json!(true), "a move: {moved}");
    assert_eq!(moved["parent_id"], json!(music), "{moved}");

    let both = w
        .update_folder(json!({ "id": design, "name": "Design", "parent_id": games }))
        .await;
    assert_eq!(both["changed"], json!(true), "a rename and a move: {both}");
    assert_eq!(both["name"], json!("Design"), "{both}");
    assert_eq!(both["parent_id"], json!(games), "{both}");

    let rooted = w
        .update_folder(json!({ "id": design, "to_root": true }))
        .await;
    assert_eq!(
        rooted["changed"],
        json!(true),
        "a move to the root: {rooted}"
    );
    assert_eq!(rooted["parent_id"], Value::Null, "{rooted}");

    let recased = w
        .update_folder(json!({ "id": design, "name": "design" }))
        .await;
    assert_eq!(
        recased["changed"],
        json!(true),
        "a case-only rename: {recased}"
    );
    assert_eq!(recased["name"], json!("design"), "{recased}");
}

// ======================================================================
// AC 7: add_to_smart_folder returns `added`; remove_from_smart_folder
// returns `removed`.
// ======================================================================

#[tokio::test]
async fn add_to_smart_folder_returns_added_true_then_added_false_for_the_same_topic() {
    let w = world().await;
    let folder = w.folder("Games", None).await;
    let topic = w
        .agent_note("Player Loop", "About it.", Some("topic"))
        .await;

    let first = w.add_member(&folder, &topic).await;
    assert_eq!(first["added"], json!(true), "{first}");
    assert!(w.is_member(&folder, &topic).await);

    let again = w.add_member(&folder, &topic).await;
    assert_eq!(again["added"], json!(false), "{again}");
    assert_eq!(again["note_id"], json!(topic), "{again}");
    assert_eq!(again["pinned"], json!(false), "{again}");
}

#[tokio::test]
async fn add_to_smart_folder_returns_added_false_over_a_persons_pinned_membership() {
    let w = world().await;
    let folder = w.folder("Games", None).await;
    let topic = w
        .agent_note("Player Loop", "About it.", Some("topic"))
        .await;
    {
        let mut vault = w.state.vault.lock().await;
        sf::add_member(
            &mut vault,
            &folder,
            &topic,
            Some(true),
            Caller::Person,
            None,
        )
        .unwrap();
    }

    let got = w.add_member(&folder, &topic).await;

    assert_eq!(got["added"], json!(false), "{got}");
    assert_eq!(got["pinned"], json!(true), "the person's pin stays: {got}");
}

#[tokio::test]
async fn remove_from_smart_folder_returns_removed_true_then_removed_false() {
    let w = world().await;
    let folder = w.folder("Games", None).await;
    let topic = w
        .agent_note("Player Loop", "About it.", Some("topic"))
        .await;
    w.add_member(&folder, &topic).await;

    let first = w.remove_member(&folder, &topic).await;
    assert_eq!(first["removed"], json!(true), "{first}");
    assert!(!w.is_member(&folder, &topic).await);

    let again = w.remove_member(&folder, &topic).await;
    assert!(
        again.get("error").is_none(),
        "a repeat is not an error: {again}"
    );
    assert_eq!(again["removed"], json!(false), "{again}");
    assert_eq!(again["smart_folder_id"], json!(folder), "{again}");
    assert_eq!(again["note_id"], json!(topic), "{again}");
    assert_eq!(again["vault_id"], json!(w.vault_id().await), "{again}");
}

#[tokio::test]
async fn remove_from_smart_folder_returns_removed_false_for_a_topic_never_added() {
    let w = world().await;
    let folder = w.folder("Games", None).await;
    let member = w
        .agent_note("Player Loop", "About it.", Some("topic"))
        .await;
    let outsider = w.agent_note("Sleep", "About sleep.", Some("topic")).await;
    w.add_member(&folder, &member).await;

    let got = w.remove_member(&folder, &outsider).await;

    assert!(got.get("error").is_none(), "{got}");
    assert_eq!(got["removed"], json!(false), "{got}");
    assert!(w.is_member(&folder, &member).await, "the member stays");
}

/// An agent's call on a folder the person pinned: a note that was never a member
/// is `removed: false` (nothing to protect), a member is still `pinned_rule`.
#[tokio::test]
async fn remove_from_smart_folder_on_a_pinned_folder_answers_false_for_a_non_member() {
    let w = world().await;
    let member = w
        .agent_note("Player Loop", "About it.", Some("topic"))
        .await;
    let outsider = w.agent_note("Sleep", "About sleep.", Some("topic")).await;
    let folder = {
        let mut vault = w.state.vault.lock().await;
        let clock = memex_core::SystemClock;
        let folder = sf::create_folder(&mut vault, "Pinned", None, Caller::Person, &clock).unwrap();
        sf::add_member(&mut vault, &folder.id, &member, None, Caller::Person, None).unwrap();
        folder.id
    };

    let got = w.remove_member(&folder, &outsider).await;
    assert!(got.get("error").is_none(), "{got}");
    assert_eq!(got["removed"], json!(false), "{got}");

    let held = w.remove_member(&folder, &member).await;
    assert_eq!(held["error"]["code"], json!("pinned_rule"), "{held}");
    assert!(w.is_member(&folder, &member).await, "the member stays");
}

/// Guard: only a non-member answers `removed: false`; a folder that doesn't
/// exist is still the not-found error it is today (`err_from`'s op code,
/// message `not found: …`).
#[tokio::test]
async fn remove_from_smart_folder_on_an_unknown_folder_is_still_not_found() {
    let w = world().await;
    let topic = w
        .agent_note("Player Loop", "About it.", Some("topic"))
        .await;

    let got = w.remove_member("01ARZ3NDEKTSV4RRFFQ69G5FAV", &topic).await;

    assert_eq!(keys(&got), set(&["error"]), "only `error`: {got}");
    let message = got["error"]["message"].as_str().unwrap_or_default();
    assert!(message.starts_with("not found"), "{got}");
}

// ======================================================================
// AC 8: add_to_canvas returns `added`, move_node `changed`,
// remove_from_canvas `removed`.
// ======================================================================

#[tokio::test]
async fn add_to_canvas_returns_added_true_for_a_new_placement_and_false_for_the_existing_one() {
    let w = world().await;
    let canvas = w.canvas("Board").await;
    let note = w.agent_note("Note A", "# Note A\n", None).await;

    let first = w.place(&canvas, &note, 1.0, 2.0).await;
    assert_eq!(first["added"], json!(true), "{first}");
    let version = w.canvas_version(&canvas).await;

    let again = w.place(&canvas, &note, 50.0, 60.0).await;
    assert_eq!(again["added"], json!(false), "{again}");
    assert_eq!(
        (again["x"].as_f64(), again["y"].as_f64()),
        (Some(1.0), Some(2.0)),
        "the existing placement: {again}"
    );
    assert_eq!(again["placed_at"], first["placed_at"], "{again}");
    assert_eq!(
        w.canvas_version(&canvas).await,
        version,
        "nothing is written"
    );
}

#[tokio::test]
async fn move_node_returns_changed_false_for_the_current_position_and_true_otherwise() {
    let w = world().await;
    let canvas = w.canvas("Board").await;
    let note = w.agent_note("Note A", "# Note A\n", None).await;
    w.place(&canvas, &note, 1.0, 2.0).await;

    // (x, y, z_order, changed, what); each row starts where the last ended.
    let cases: [(f64, f64, Option<i64>, bool, &str); 8] = [
        (1.0, 2.0, None, false, "the current x and y"),
        (1.0, 2.0, Some(0), false, "the current x, y and z_order"),
        (3.0, 2.0, None, true, "a new x"),
        (3.0, 4.0, None, true, "a new y"),
        (3.0, 4.0, Some(5), true, "a new z_order"),
        (3.0, 4.0, None, false, "unchanged, z_order omitted"),
        (3.0, 4.0, Some(5), false, "unchanged, z_order given"),
        (-3.5, 4.25, Some(0), true, "everything new"),
    ];
    for (x, y, z, changed, what) in cases {
        let got = w.move_node(&canvas, &note, x, y, z).await;
        assert!(got.get("error").is_none(), "{what}: {got}");
        assert_eq!(got["changed"], json!(changed), "{what}: {got}");
        assert_eq!(
            (got["x"].as_f64(), got["y"].as_f64()),
            (Some(x), Some(y)),
            "{what}: {got}"
        );
    }
}

#[tokio::test]
async fn remove_from_canvas_returns_removed_true_then_removed_false() {
    let w = world().await;
    let canvas = w.canvas("Board").await;
    let note = w.agent_note("Note A", "# Note A\n", None).await;
    let never = w.agent_note("Note B", "# Note B\n", None).await;
    w.place(&canvas, &note, 1.0, 2.0).await;

    let first = w.unplace(&canvas, &note).await;
    assert_eq!(first["removed"], json!(true), "{first}");
    let version = w.canvas_version(&canvas).await;

    let again = w.unplace(&canvas, &note).await;
    assert_eq!(again["removed"], json!(false), "a repeat: {again}");
    assert_eq!(again["note_id"], json!(note), "{again}");

    let unplaced = w.unplace(&canvas, &never).await;
    assert_eq!(
        unplaced["removed"],
        json!(false),
        "never placed: {unplaced}"
    );
    assert_eq!(
        w.canvas_version(&canvas).await,
        version,
        "nothing is written"
    );
}

// ======================================================================
// AC 9: every existing result key stays; the new field sits beside them.
// ======================================================================

#[tokio::test]
async fn every_new_field_sits_beside_the_tools_existing_result_keys() {
    let w = world().await;
    w.day().await;
    let topic = w
        .person_note("Player Loop", "About it.\n", Some("topic"))
        .await;
    let note = w.person_note("Plain", "Person text.\n", None).await;
    let (_, link) = w.link().await;
    let folder = w.folder("Games", None).await;
    let member = w
        .agent_note("Jump Arc", "About jumps.", Some("topic"))
        .await;
    let canvas = w.canvas("Board").await;
    let placed = w.agent_note("Note A", "# Note A\n", None).await;

    const EXCERPT: [&str; 3] = ["vault_id", "topic_note_id", "version"];
    const NODE: [&str; 8] = [
        "vault_id",
        "canvas_id",
        "note_id",
        "note_title",
        "x",
        "y",
        "z_order",
        "placed_at",
    ];
    let results: Vec<(&str, Value, Vec<&str>, &str)> = vec![
        (
            "add_excerpt",
            w.add_excerpt(&topic, &[B7, C3, F6]).await,
            EXCERPT.to_vec(),
            "filed_block_ids",
        ),
        (
            "remove_excerpt_block",
            w.remove_excerpt_block(&topic, C3).await,
            EXCERPT.to_vec(),
            "removed",
        ),
        (
            "remove_excerpt",
            w.remove_excerpt(&topic, &[B7]).await,
            EXCERPT.to_vec(),
            "removed_count",
        ),
        (
            "add_footer_topic",
            w.add_footer_topic(&note, &topic).await,
            vec!["vault_id", "note_id", "topic_note_id", "origin", "version"],
            "changed",
        ),
        (
            "update_link",
            w.update_link(json!({ "link_id": link, "kind": "extends" }))
                .await,
            vec![
                "vault_id",
                "link_id",
                "from_note_id",
                "to_note_id",
                "kind",
                "label",
                "source",
                "position",
            ],
            "changed",
        ),
        (
            "update_smart_folder",
            w.update_folder(json!({ "id": folder, "name": "Gaming" }))
                .await,
            vec![
                "vault_id",
                "id",
                "name",
                "parent_id",
                "pinned",
                "depth",
                "created_at",
                "updated_at",
            ],
            "changed",
        ),
        (
            "add_to_smart_folder",
            w.add_member(&folder, &member).await,
            vec![
                "vault_id",
                "smart_folder_id",
                "note_id",
                "pinned",
                "role_set",
            ],
            "added",
        ),
        (
            "remove_from_smart_folder",
            w.remove_member(&folder, &member).await,
            vec!["vault_id", "smart_folder_id", "note_id", "removed"],
            "removed",
        ),
        (
            "add_to_canvas",
            w.place(&canvas, &placed, 1.0, 2.0).await,
            NODE.to_vec(),
            "added",
        ),
        (
            "move_node",
            w.move_node(&canvas, &placed, 3.0, 4.0, None).await,
            NODE.to_vec(),
            "changed",
        ),
        (
            "remove_from_canvas",
            w.unplace(&canvas, &placed).await,
            vec!["vault_id", "canvas_id", "note_id"],
            "removed",
        ),
    ];
    for (tool, got, existing, field) in results {
        let mut want = set(&existing);
        want.insert(field.to_string());
        assert_eq!(
            keys(&got),
            want,
            "{tool}: every existing key plus `{field}`: {got}"
        );
    }
}

// ======================================================================
// AC 11: each new field is named in its tool's description.
// ======================================================================

/// Whether `word` occurs in `text` as a whole identifier (not inside a longer
/// one such as `removed_count` or `unchanged`).
fn names(text: &str, word: &str) -> bool {
    let is_ident = |c: char| c.is_ascii_alphanumeric() || c == '_';
    text.match_indices(word).any(|(at, _)| {
        let before = text[..at].chars().next_back();
        let after = text[at + word.len()..].chars().next();
        !before.is_some_and(is_ident) && !after.is_some_and(is_ident)
    })
}

#[tokio::test]
async fn each_new_result_field_is_named_in_its_tool_description() {
    let w = world().await;
    let tools = w.client.list_all_tools().await.expect("tools/list");

    let fields = [
        ("add_excerpt", "filed_block_ids"),
        ("remove_excerpt", "removed_count"),
        ("remove_excerpt_block", "removed"),
        ("add_footer_topic", "changed"),
        ("update_link", "changed"),
        ("update_smart_folder", "changed"),
        ("add_to_smart_folder", "added"),
        ("remove_from_smart_folder", "removed"),
        ("add_to_canvas", "added"),
        ("move_node", "changed"),
        ("remove_from_canvas", "removed"),
    ];
    for (tool, field) in fields {
        let description = tools
            .iter()
            .find(|t| t.name == tool)
            .unwrap_or_else(|| panic!("{tool} is listed"))
            .description
            .as_deref()
            .unwrap_or_else(|| panic!("{tool} has a description"));
        // The field is named where the description says what the tool
        // returns, not merely as a word elsewhere ("cannot be removed").
        let returns = description
            .find("Return")
            .map(|at| &description[at..])
            .unwrap_or_else(|| {
                panic!("{tool}: the description says what it returns: {description}")
            });
        assert!(
            names(returns, field),
            "{tool}: `{field}` is named in what it returns: {description}"
        );
    }
}

#[test]
fn names_matches_whole_identifiers_only() {
    assert!(names("Returns removed and version.", "removed"));
    assert!(names("Returns `removed` (false when absent).", "removed"));
    assert!(!names("Returns removed_count.", "removed"));
    assert!(!names("Returns unchanged.", "changed"));
    assert!(!names("Returns nothing.", "changed"));
}
