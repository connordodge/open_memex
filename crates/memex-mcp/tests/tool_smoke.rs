//! End-to-end-ish smoke test for the MCP tool surface.
//! Exercises the tool methods directly (not over the MCP wire) so that
//! programming errors in the wiring surface in plain `cargo test`.

use std::sync::Arc;

use memex_mcp::state::AppState;
use memex_mcp::tools::{
    AddLinkParams, AddToCanvasParams, CreateCanvasParams, CreateNoteParams, DeleteCanvasParams,
    GetCanvasParams, GetNoteParams, ListCanvasesParams, Memex, MoveNodeParams, NeighborsParams,
    RemoveFromCanvasParams, SearchParams, UpdateLinkParams,
};
use rmcp::handler::server::wrapper::Parameters;
use serde_json::Value;

fn fresh_state() -> Arc<AppState> {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().to_path_buf();
    // tempdir is leaked intentionally so the vault outlives this fn.
    std::mem::forget(dir);
    let vault = memex_core::Vault::create(&path).unwrap();
    Arc::new(AppState::new(vault, path, None))
}

#[tokio::test]
async fn create_then_search_then_get_note_round_trip() {
    let memex = Memex::new(fresh_state());

    let create_resp = memex
        .create_note(Parameters(CreateNoteParams {
            content_md:
                "# Hybrid search\n\nWe combine BM25 with vector cosine via RRF.".into(),
            title: Some("Hybrid search".into()),
            tags: Some(vec!["arch".into()]),
            agent_id: Some("smoke-test".into()),
            role: None,
        }))
        .await;
    let created: Value = serde_json::from_str(&create_resp).unwrap();
    let note_id = created["note_id"].as_str().expect("note_id").to_string();

    let search_resp = memex
        .search(Parameters(SearchParams {
            query: "hybrid".into(),
            k: Some(5),
            mode: Some("fts".into()),
            tags: None,
            note_id: None,
        }))
        .await;
    let s: Value = serde_json::from_str(&search_resp).unwrap();
    let results = s["results"].as_array().expect("results array");
    assert!(!results.is_empty(), "expected at least one result");
    assert_eq!(results[0]["note_id"].as_str().unwrap(), note_id);

    let get_resp = memex
        .get_note(Parameters(GetNoteParams {
            note_id: note_id.clone(),
            include_backlinks: None,
        }))
        .await;
    let g: Value = serde_json::from_str(&get_resp).unwrap();
    assert_eq!(g["note_id"].as_str().unwrap(), note_id);
    assert!(g["content_md"].as_str().unwrap().contains("BM25"));
    let tags = g["tags"].as_array().unwrap();
    let tag_strs: Vec<&str> = tags.iter().filter_map(|v| v.as_str()).collect();
    assert!(tag_strs.contains(&"arch"));
    assert!(tag_strs.contains(&"inbox"));
    assert!(tag_strs.contains(&"agent-authored"));
}

#[tokio::test]
async fn search_with_empty_query_returns_no_results() {
    let memex = Memex::new(fresh_state());
    let resp = memex
        .search(Parameters(SearchParams {
            query: "".into(),
            k: Some(5),
            mode: None,
            tags: None,
            note_id: None,
        }))
        .await;
    let v: Value = serde_json::from_str(&resp).unwrap();
    assert_eq!(v["results"].as_array().unwrap().len(), 0);
}

#[tokio::test]
async fn get_note_with_invalid_id_returns_structured_error() {
    let memex = Memex::new(fresh_state());
    let resp = memex
        .get_note(Parameters(GetNoteParams {
            note_id: "not-a-ulid".into(),
            include_backlinks: None,
        }))
        .await;
    let v: Value = serde_json::from_str(&resp).unwrap();
    assert!(v["error"].is_object(), "expected error object, got {v}");
    assert_eq!(v["error"]["code"].as_str().unwrap(), "get_note.invalid_id");
}

async fn create_simple_note(memex: &Memex, title: &str, body: &str) -> String {
    let resp = memex
        .create_note(Parameters(CreateNoteParams {
            content_md: body.to_string(),
            title: Some(title.to_string()),
            tags: None,
            agent_id: Some("smoke".into()),
            role: None,
        }))
        .await;
    let v: Value = serde_json::from_str(&resp).unwrap();
    v["note_id"].as_str().unwrap().to_string()
}

#[tokio::test]
async fn get_note_with_include_backlinks_returns_grouped_maps() {
    let memex = Memex::new(fresh_state());
    let target = create_simple_note(&memex, "Target", "x").await;
    let _src = create_simple_note(
        &memex,
        "Source",
        "## Contradicts\n\n[[Target]]\n\n## Extends\n\n[[Target~extends]]\n",
    )
    .await;
    // Have Source's links resolve to Target by reindexing — since `## Extends`
    // isn't a curated heading mapping (extends is the kind for the explicit
    // `~extends` though), this gives us at least a contradicts edge from
    // section grouping plus an explicit extends edge.

    let resp = memex
        .get_note(Parameters(GetNoteParams {
            note_id: target.clone(),
            include_backlinks: Some(true),
        }))
        .await;
    let v: Value = serde_json::from_str(&resp).expect("json");
    assert!(v["backlinks"].is_object(), "expected backlinks map: {v}");
    let bl = v["backlinks"].as_object().unwrap();
    let kinds: Vec<&str> = bl.keys().map(|s| s.as_str()).collect();
    assert!(kinds.contains(&"contradicts"), "kinds: {kinds:?}");
    assert!(kinds.contains(&"extends"), "kinds: {kinds:?}");
}

#[tokio::test]
async fn get_note_without_include_backlinks_omits_links_keys() {
    let memex = Memex::new(fresh_state());
    let id = create_simple_note(&memex, "Solo", "body").await;
    let resp = memex
        .get_note(Parameters(GetNoteParams {
            note_id: id,
            include_backlinks: None,
        }))
        .await;
    let v: Value = serde_json::from_str(&resp).unwrap();
    assert!(v.get("links").is_none() || v["links"].is_null());
    assert!(v.get("backlinks").is_none() || v["backlinks"].is_null());
}

#[tokio::test]
async fn add_link_default_kind_inserts_into_auto_added_section() {
    let memex = Memex::new(fresh_state());
    let from = create_simple_note(&memex, "Source", "body.\n").await;
    let to = create_simple_note(&memex, "Target", "x").await;

    let resp = memex
        .add_link(Parameters(AddLinkParams {
            from_id: from.clone(),
            to_id: to.clone(),
            kind: None,
            label: None,
        }))
        .await;
    let v: Value = serde_json::from_str(&resp).unwrap();
    assert_eq!(v["was_existing"], false);
    assert_eq!(v["kind"], "references");
    assert_eq!(v["source"], "auto_added");

    // Verify by reading the source note: body now has the auto-added section.
    let g = memex
        .get_note(Parameters(GetNoteParams {
            note_id: from,
            include_backlinks: None,
        }))
        .await;
    let body = serde_json::from_str::<Value>(&g).unwrap()["content_md"]
        .as_str()
        .unwrap()
        .to_string();
    assert!(body.contains("## Auto-added links"));
    assert!(body.contains("[[Target]]"));
}

#[tokio::test]
async fn add_link_typed_kind_writes_to_frontmatter() {
    let memex = Memex::new(fresh_state());
    let from = create_simple_note(&memex, "Source", "body").await;
    let to = create_simple_note(&memex, "Target", "x").await;

    let resp = memex
        .add_link(Parameters(AddLinkParams {
            from_id: from.clone(),
            to_id: to.clone(),
            kind: Some("contradicts".into()),
            label: None,
        }))
        .await;
    let v: Value = serde_json::from_str(&resp).unwrap();
    assert_eq!(v["kind"], "contradicts");
    assert_eq!(v["source"], "frontmatter");

    let g = memex
        .get_note(Parameters(GetNoteParams {
            note_id: from,
            include_backlinks: None,
        }))
        .await;
    let body = serde_json::from_str::<Value>(&g).unwrap()["content_md"]
        .as_str()
        .unwrap()
        .to_string();
    assert!(body.starts_with("---\n"));
    assert!(body.contains("contradicts:\n  - [[Target]]"));
}

#[tokio::test]
async fn add_link_user_defined_kind_is_first_class() {
    let memex = Memex::new(fresh_state());
    let from = create_simple_note(&memex, "Source", "body").await;
    let to = create_simple_note(&memex, "Bush", "x").await;

    let resp = memex
        .add_link(Parameters(AddLinkParams {
            from_id: from,
            to_id: to,
            kind: Some("inspired-by".into()),
            label: None,
        }))
        .await;
    let v: Value = serde_json::from_str(&resp).unwrap();
    assert_eq!(v["kind"], "inspired-by");
    assert_eq!(v["source"], "frontmatter");
}

#[tokio::test]
async fn add_link_idempotent_returns_was_existing_true() {
    let memex = Memex::new(fresh_state());
    let from = create_simple_note(&memex, "A", "body").await;
    let to = create_simple_note(&memex, "B", "x").await;

    let first = memex
        .add_link(Parameters(AddLinkParams {
            from_id: from.clone(),
            to_id: to.clone(),
            kind: None,
            label: None,
        }))
        .await;
    let v1: Value = serde_json::from_str(&first).unwrap();
    let id1 = v1["link_id"].as_str().unwrap().to_string();

    let second = memex
        .add_link(Parameters(AddLinkParams {
            from_id: from,
            to_id: to,
            kind: None,
            label: None,
        }))
        .await;
    let v2: Value = serde_json::from_str(&second).unwrap();
    assert_eq!(v2["was_existing"], true);
    assert_eq!(v2["link_id"].as_str().unwrap(), id1);
}

#[tokio::test]
async fn add_link_invalid_kind_returns_error() {
    let memex = Memex::new(fresh_state());
    let from = create_simple_note(&memex, "A", "body").await;
    let to = create_simple_note(&memex, "B", "x").await;

    let resp = memex
        .add_link(Parameters(AddLinkParams {
            from_id: from,
            to_id: to,
            kind: Some("Made_Up".into()),
            label: None,
        }))
        .await;
    let v: Value = serde_json::from_str(&resp).unwrap();
    assert!(v["error"].is_object());
    assert_eq!(v["error"]["code"], "add_link.invalid_kind");
}

#[tokio::test]
async fn add_link_unknown_target_returns_error() {
    let memex = Memex::new(fresh_state());
    let from = create_simple_note(&memex, "A", "body").await;

    let resp = memex
        .add_link(Parameters(AddLinkParams {
            from_id: from,
            to_id: "01HXXXXXXXXXXXXXXXXXXXXXXX".into(), // valid ULID format, no row
            kind: None,
            label: None,
        }))
        .await;
    let v: Value = serde_json::from_str(&resp).unwrap();
    assert!(v["error"].is_object());
    assert_eq!(v["error"]["code"], "add_link.to_not_found");
}

#[tokio::test]
async fn neighbors_returns_bfs_results_with_edge_metadata() {
    let memex = Memex::new(fresh_state());
    let root = create_simple_note(&memex, "Root", "body").await;
    let n1 = create_simple_note(&memex, "Friend", "x").await;
    let n2 = create_simple_note(&memex, "Friend2", "y").await;

    // Root → Friend (contradicts), Root → Friend2 (extends).
    memex
        .add_link(Parameters(AddLinkParams {
            from_id: root.clone(),
            to_id: n1.clone(),
            kind: Some("contradicts".into()),
            label: None,
        }))
        .await;
    memex
        .add_link(Parameters(AddLinkParams {
            from_id: root.clone(),
            to_id: n2.clone(),
            kind: Some("extends".into()),
            label: None,
        }))
        .await;

    let resp = memex
        .neighbors(Parameters(NeighborsParams {
            note_id: root.clone(),
            depth: Some(1),
            kind: None,
        }))
        .await;
    let v: Value = serde_json::from_str(&resp).unwrap();
    assert_eq!(v["root_note_id"].as_str().unwrap(), root);
    assert_eq!(v["depth"].as_i64().unwrap(), 1);
    let results = v["results"].as_array().unwrap();
    assert_eq!(results.len(), 2);
    let ids: Vec<&str> = results
        .iter()
        .map(|r| r["note_id"].as_str().unwrap())
        .collect();
    assert!(ids.contains(&n1.as_str()));
    assert!(ids.contains(&n2.as_str()));
}

#[tokio::test]
async fn neighbors_kind_filter_restricts_edges_followed() {
    let memex = Memex::new(fresh_state());
    let root = create_simple_note(&memex, "Root", "body").await;
    let cont = create_simple_note(&memex, "Contra", "x").await;
    let ext = create_simple_note(&memex, "Ext", "y").await;
    memex
        .add_link(Parameters(AddLinkParams {
            from_id: root.clone(),
            to_id: cont.clone(),
            kind: Some("contradicts".into()),
            label: None,
        }))
        .await;
    memex
        .add_link(Parameters(AddLinkParams {
            from_id: root.clone(),
            to_id: ext.clone(),
            kind: Some("extends".into()),
            label: None,
        }))
        .await;

    let resp = memex
        .neighbors(Parameters(NeighborsParams {
            note_id: root,
            depth: Some(1),
            kind: Some("contradicts".into()),
        }))
        .await;
    let v: Value = serde_json::from_str(&resp).unwrap();
    let results = v["results"].as_array().unwrap();
    assert_eq!(results.len(), 1);
    assert_eq!(results[0]["note_id"].as_str().unwrap(), cont);
}

#[tokio::test]
async fn neighbors_clamps_depth_to_max() {
    let memex = Memex::new(fresh_state());
    let root = create_simple_note(&memex, "R", "body").await;
    let resp = memex
        .neighbors(Parameters(NeighborsParams {
            note_id: root,
            depth: Some(99),
            kind: None,
        }))
        .await;
    let v: Value = serde_json::from_str(&resp).unwrap();
    assert_eq!(v["depth"].as_i64().unwrap(), 3);
}

#[tokio::test]
async fn neighbors_invalid_kind_returns_error() {
    let memex = Memex::new(fresh_state());
    let root = create_simple_note(&memex, "R", "body").await;
    let resp = memex
        .neighbors(Parameters(NeighborsParams {
            note_id: root,
            depth: Some(1),
            kind: Some("Made_Up".into()),
        }))
        .await;
    let v: Value = serde_json::from_str(&resp).unwrap();
    assert!(v["error"].is_object());
    assert_eq!(v["error"]["code"], "neighbors.invalid_kind");
}

#[tokio::test]
async fn neighbors_invalid_note_id_returns_error() {
    let memex = Memex::new(fresh_state());
    let resp = memex
        .neighbors(Parameters(NeighborsParams {
            note_id: "not-a-ulid".into(),
            depth: None,
            kind: None,
        }))
        .await;
    let v: Value = serde_json::from_str(&resp).unwrap();
    assert!(v["error"].is_object());
    assert_eq!(v["error"]["code"], "neighbors.invalid_id");
}

// ---------- canvas tools ----------

async fn make_note(memex: &Memex, title: &str, body: &str) -> String {
    let resp = memex
        .create_note(Parameters(CreateNoteParams {
            content_md: body.into(),
            title: Some(title.into()),
            tags: None,
            agent_id: Some("smoke".into()),
            role: None,
        }))
        .await;
    let v: Value = serde_json::from_str(&resp).unwrap();
    v["note_id"].as_str().unwrap().to_string()
}

async fn make_canvas(memex: &Memex, title: &str) -> String {
    let resp = memex
        .create_canvas(Parameters(CreateCanvasParams {
            title: title.into(),
        }))
        .await;
    let v: Value = serde_json::from_str(&resp).unwrap();
    v["canvas_id"].as_str().unwrap().to_string()
}

#[tokio::test]
async fn create_canvas_round_trip_and_list() {
    let memex = Memex::new(fresh_state());
    let cid = make_canvas(&memex, "Board A").await;

    let listed = memex
        .list_canvases(Parameters(ListCanvasesParams {}))
        .await;
    let v: Value = serde_json::from_str(&listed).unwrap();
    let canvases = v["canvases"].as_array().unwrap();
    assert_eq!(canvases.len(), 1);
    assert_eq!(canvases[0]["canvas_id"].as_str().unwrap(), cid);
    assert_eq!(canvases[0]["title"].as_str().unwrap(), "Board A");
    assert_eq!(canvases[0]["node_count"].as_i64().unwrap(), 0);
}

#[tokio::test]
async fn create_canvas_duplicate_title_returns_title_conflict_error() {
    let memex = Memex::new(fresh_state());
    let _ = make_canvas(&memex, "Dup").await;
    let resp = memex
        .create_canvas(Parameters(CreateCanvasParams { title: "Dup".into() }))
        .await;
    let v: Value = serde_json::from_str(&resp).unwrap();
    assert_eq!(v["error"]["code"], "create_canvas.title_conflict");
}

#[tokio::test]
async fn add_to_canvas_defaults_x_y_to_zero() {
    let memex = Memex::new(fresh_state());
    let cid = make_canvas(&memex, "Board").await;
    let nid = make_note(&memex, "Note A", "# Note A\n").await;
    let resp = memex
        .add_to_canvas(Parameters(AddToCanvasParams {
            canvas_id: cid.clone(),
            note_id: nid.clone(),
            x: None,
            y: None,
        }))
        .await;
    let v: Value = serde_json::from_str(&resp).unwrap();
    assert_eq!(v["x"].as_f64().unwrap(), 0.0);
    assert_eq!(v["y"].as_f64().unwrap(), 0.0);
    assert_eq!(v["note_title"].as_str().unwrap(), "Note A");
}

#[tokio::test]
async fn get_canvas_returns_placed_nodes_and_edges_between_them() {
    let memex = Memex::new(fresh_state());
    let cid = make_canvas(&memex, "Board").await;
    let beta_id = make_note(&memex, "Beta", "# Beta\n").await;
    let _gamma_id = make_note(&memex, "Gamma", "# Gamma\n").await;
    let alpha_id = make_note(&memex, "Alpha", "# Alpha\n\n[[Beta]] and [[Gamma]]").await;
    memex
        .add_to_canvas(Parameters(AddToCanvasParams {
            canvas_id: cid.clone(),
            note_id: alpha_id.clone(),
            x: Some(1.0),
            y: Some(2.0),
        }))
        .await;
    memex
        .add_to_canvas(Parameters(AddToCanvasParams {
            canvas_id: cid.clone(),
            note_id: beta_id.clone(),
            x: Some(10.0),
            y: Some(20.0),
        }))
        .await;

    let resp = memex
        .get_canvas(Parameters(GetCanvasParams {
            canvas_id: cid.clone(),
        }))
        .await;
    let v: Value = serde_json::from_str(&resp).unwrap();
    assert_eq!(v["canvas_id"].as_str().unwrap(), cid);
    assert_eq!(v["nodes"].as_array().unwrap().len(), 2);
    let edges = v["edges"].as_array().unwrap();
    assert_eq!(edges.len(), 1, "Gamma is off-canvas; only Alpha->Beta renders");
    assert_eq!(edges[0]["from_note_id"].as_str().unwrap(), alpha_id);
    assert_eq!(edges[0]["to_note_id"].as_str().unwrap(), beta_id);
}

#[tokio::test]
async fn get_canvas_unknown_id_returns_structured_error() {
    let memex = Memex::new(fresh_state());
    let resp = memex
        .get_canvas(Parameters(GetCanvasParams {
            canvas_id: "not-a-ulid".into(),
        }))
        .await;
    let v: Value = serde_json::from_str(&resp).unwrap();
    assert_eq!(v["error"]["code"], "get_canvas.invalid_id");
}

#[tokio::test]
async fn remove_from_canvas_then_move_node_errors() {
    let memex = Memex::new(fresh_state());
    let cid = make_canvas(&memex, "Board").await;
    let nid = make_note(&memex, "Note", "# Note\n").await;
    memex
        .add_to_canvas(Parameters(AddToCanvasParams {
            canvas_id: cid.clone(),
            note_id: nid.clone(),
            x: Some(1.0),
            y: Some(1.0),
        }))
        .await;
    memex
        .remove_from_canvas(Parameters(RemoveFromCanvasParams {
            canvas_id: cid.clone(),
            note_id: nid.clone(),
        }))
        .await;
    let resp = memex
        .move_node(Parameters(MoveNodeParams {
            canvas_id: cid.clone(),
            note_id: nid.clone(),
            x: 9.0,
            y: 9.0,
            z_order: None,
        }))
        .await;
    let v: Value = serde_json::from_str(&resp).unwrap();
    assert!(v["error"].is_object(), "expected an error payload: {v}");
}

#[tokio::test]
async fn delete_canvas_with_wrong_expected_version_errors() {
    let memex = Memex::new(fresh_state());
    let cid = make_canvas(&memex, "Board").await;
    // Bump version via a placement.
    let nid = make_note(&memex, "Note", "# Note\n").await;
    memex
        .add_to_canvas(Parameters(AddToCanvasParams {
            canvas_id: cid.clone(),
            note_id: nid,
            x: None,
            y: None,
        }))
        .await;
    let resp = memex
        .delete_canvas(Parameters(DeleteCanvasParams {
            canvas_id: cid,
            expected_version: 1, // stale; placement bumped to 2
        }))
        .await;
    let v: Value = serde_json::from_str(&resp).unwrap();
    assert!(v["error"].is_object(), "expected an error payload: {v}");
}

// ---------- update_link tool ----------

#[tokio::test]
async fn update_link_changes_kind_in_place_via_tool() {
    let memex = Memex::new(fresh_state());
    let _target = make_note(&memex, "Target", "# Target\n").await;
    let source = make_note(&memex, "Source", "Hello [[Target]] world.").await;

    // Find the link id (one outgoing link from source).
    let n = memex
        .get_note(Parameters(GetNoteParams {
            note_id: source.clone(),
            include_backlinks: Some(true),
        }))
        .await;
    let v: Value = serde_json::from_str(&n).unwrap();
    let link_id = v["links"]["references"][0]["link_id"]
        .as_str()
        .expect("link_id from references")
        .to_string();

    let resp = memex
        .update_link(Parameters(UpdateLinkParams {
            link_id: link_id.clone(),
            kind: Some("extends".into()),
            label: Some("the goal".into()),
            clear_label: None,
        }))
        .await;
    let v: Value = serde_json::from_str(&resp).unwrap();
    assert_eq!(v["kind"].as_str().unwrap(), "extends");
    assert_eq!(v["label"].as_str().unwrap(), "the goal");
}

#[tokio::test]
async fn update_link_unknown_id_returns_error() {
    let memex = Memex::new(fresh_state());
    let resp = memex
        .update_link(Parameters(UpdateLinkParams {
            link_id: "nope".into(),
            kind: Some("extends".into()),
            label: None,
            clear_label: None,
        }))
        .await;
    let v: Value = serde_json::from_str(&resp).unwrap();
    assert!(v["error"].is_object(), "expected an error payload: {v}");
}
