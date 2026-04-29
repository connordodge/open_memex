//! End-to-end-ish smoke test for the MCP tool surface.
//! Exercises the tool methods directly (not over the MCP wire) so that
//! programming errors in the wiring surface in plain `cargo test`.

use std::sync::Arc;

use memex_mcp::state::AppState;
use memex_mcp::tools::{
    CreateNoteParams, GetNoteParams, Memex, SearchParams,
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
