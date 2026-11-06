//! WI #239 (T3): `add_link` changes no body tags (Spec #234 R3).
//!
//! The agent's `add_link` tool saves through the agent path, so text no scan
//! has seen stays unscanned. The person's `memex link add` op saves through
//! the person path, where a re-derivation over already scanned text writes no
//! row. Both count row changes with temp triggers on `tags`.

use std::sync::Arc;

use memex_core::notes::{self, CreateNote, Note, NoteId};
use memex_core::{indexer, Caller, SystemClock, Vault};
use memex_mcp::ops::links::{self as ops, AddLinkInput};
use memex_mcp::state::AppState;
use memex_mcp::tools::Memex;
use rmcp::handler::server::wrapper::Parameters;
use rusqlite::params;
use serde_json::{json, Value};

fn create(vault: &mut Vault, title: &str, body: &str, role: Option<&str>) -> Note {
    let note = notes::create_note_as(
        vault,
        CreateNote {
            title: Some(title.into()),
            content_md: body.into(),
            frontmatter: role.map(|r| json!({ "role": r })),
        },
        Caller::Person,
    )
    .unwrap();
    indexer::reindex_note(
        vault.connection_mut(),
        note.id.as_str(),
        &note.content_md,
        None,
    )
    .unwrap();
    note
}

fn rows(vault: &Vault, id: &NoteId) -> Vec<(String, String)> {
    let conn = vault.connection_ref();
    let mut stmt = conn
        .prepare("SELECT tag, origin FROM tags WHERE note_id = ? ORDER BY tag")
        .unwrap();
    let found = stmt
        .query_map([id.as_str()], |r| Ok((r.get(0)?, r.get(1)?)))
        .unwrap()
        .collect::<rusqlite::Result<Vec<_>>>()
        .unwrap();
    found
}

fn kept_body_row() -> Vec<(String, String)> {
    vec![("kept".to_string(), "body".to_string())]
}

fn count_tag_writes(vault: &Vault) {
    let mut sql = String::from("CREATE TEMP TABLE tag_write_log (op TEXT NOT NULL);");
    for op in ["INSERT", "UPDATE", "DELETE"] {
        sql.push_str(&format!(
            "CREATE TEMP TRIGGER log_tags_{op} AFTER {op} ON main.tags
             BEGIN INSERT INTO tag_write_log VALUES ('{op}'); END;"
        ));
    }
    vault.connection_ref().execute_batch(&sql).unwrap();
}

fn tag_writes(vault: &Vault) -> i64 {
    vault
        .connection_ref()
        .query_row("SELECT COUNT(*) FROM tag_write_log", [], |r| r.get(0))
        .unwrap()
}

#[tokio::test]
async fn add_link_tool_changes_no_body_tags() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("vault");
    let vault = Vault::create(&path).unwrap();
    let state = Arc::new(AppState::new(vault, path, None));
    let memex = Memex::new(state.clone());
    let (source, target) = {
        let mut v = state.vault.lock().await;
        let target = create(&mut v, "Target", "Target body.\n", None);
        let source = create(&mut v, "Source", "#kept here\n", Some("topic"));
        assert_eq!(rows(&v, &source.id), kept_body_row(), "setup");
        // Text no scan has seen: the tool's write must not scan it.
        let body = "#kept here\n\n#unscanned\n";
        v.connection_ref()
            .execute(
                "UPDATE notes SET content_md = ? WHERE id = ?",
                params![body, source.id.as_str()],
            )
            .unwrap();
        count_tag_writes(&v);
        (source, target)
    };

    let args = json!({ "from_id": source.id.to_string(), "to_id": target.id.to_string() });
    let resp = memex
        .add_link(Parameters(serde_json::from_value(args).unwrap()))
        .await;
    let resp: Value = serde_json::from_str(&resp).unwrap_or_else(|e| panic!("{e}: {resp}"));
    assert!(resp.get("error").is_none(), "{resp}");

    let v = state.vault.lock().await;
    let body = notes::get_note(&v, &source.id).unwrap().content_md;
    assert!(body.contains("[[Target]]"), "{body}");
    assert_eq!(tag_writes(&v), 0);
    assert_eq!(rows(&v, &source.id), kept_body_row());
}

#[test]
fn add_link_op_on_a_scanned_body_writes_no_tag_rows() {
    let dir = tempfile::tempdir().unwrap();
    let mut vault = Vault::create(dir.path()).unwrap();
    let target = create(&mut vault, "Target", "Target body.\n", None);
    let source = create(&mut vault, "Source", "#kept here\n", None);
    assert_eq!(rows(&vault, &source.id), kept_body_row(), "setup");
    count_tag_writes(&vault);

    ops::add_link(
        &mut vault,
        AddLinkInput {
            from: source.id.to_string(),
            to: target.id.to_string(),
            kind: "references".into(),
            label: None,
        },
        &SystemClock,
        None,
    )
    .expect("ops add_link");

    let body = notes::get_note(&vault, &source.id).unwrap().content_md;
    assert!(body.contains("[[Target]]"), "{body}");
    assert_eq!(tag_writes(&vault), 0);
    assert_eq!(rows(&vault, &source.id), kept_body_row());
}
