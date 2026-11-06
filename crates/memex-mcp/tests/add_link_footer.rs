//! WI #238 (T2): `add_link` keeps the link above the Note footer marker
//! (Spec #234 R15).
//!
//! - `md_links::insert_link_into_markdown` treats only the person section as
//!   the body: the link (or its `## Auto-added links` section) goes where it
//!   would go without a footer, and the footer is kept byte for byte. A marker
//!   inside fenced code is body text.
//! - The CLI op (person) and the MCP tool (agent) store it that way.

use std::sync::Arc;

use memex_core::notes::{self, CreateNote, Note, NoteId};
use memex_core::{indexer, Caller, SystemClock, Vault};
use memex_mcp::md_links::insert_link_into_markdown;
use memex_mcp::ops::links::{self as ops, AddLinkInput};
use memex_mcp::state::AppState;
use memex_mcp::tools::Memex;
use rmcp::handler::server::wrapper::Parameters;
use rusqlite::params;
use serde_json::{json, Value};

const M: &str = "<!-- memex:topics -->";
const FOOTER: &str = "<!-- memex:topics -->\n[[Player Loop~about]]\n#work\n";

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

/// Gives `host` the footer [`FOOTER`] straight in the tables: a chip row for
/// `chip` (titled `Player Loop`), an agent tag row `work`, and the body.
fn give_footer(vault: &mut Vault, host: &Note, chip: &Note) {
    let conn = vault.connection_ref();
    conn.execute(
        "INSERT INTO footer_chips (daily_note_id, topic_note_id, origin, created_at)
         VALUES (?, ?, 'person', 0)",
        params![host.id.as_str(), chip.id.as_str()],
    )
    .unwrap();
    conn.execute(
        "INSERT INTO tags (note_id, tag, origin) VALUES (?, 'work', 'agent')",
        params![host.id.as_str()],
    )
    .unwrap();
    let body = format!("{}{FOOTER}", host.content_md);
    conn.execute(
        "UPDATE notes SET content_md = ? WHERE id = ?",
        params![body, host.id.as_str()],
    )
    .unwrap();
    indexer::reindex_note(vault.connection_mut(), host.id.as_str(), &body, None).unwrap();
}

fn stored(vault: &Vault, id: &NoteId) -> Note {
    notes::get_note(vault, id).unwrap()
}

fn link_count(vault: &Vault, from: &NoteId, to: &NoteId) -> i64 {
    vault
        .connection_ref()
        .query_row(
            "SELECT COUNT(*) FROM links WHERE from_note_id = ? AND to_note_id = ?",
            params![from.as_str(), to.as_str()],
            |r| r.get(0),
        )
        .unwrap()
}

// ---------- AC 10: md_links on a body with a footer ----------

#[test]
fn insert_link_into_markdown_keeps_the_link_above_the_footer_marker() {
    let persons = [
        "Hello there.\n",
        "Hello.\n\n## Auto-added links\n\n[[Bar]]\n",
        "## Auto-added links\n\n[[Bar]]\n\n## Other\n\nstuff\n",
        "---\nextends:\n  - [[A]]\n---\nbody\n",
    ];
    for person in persons {
        for (kind, label) in [
            ("references", None),
            ("references", Some("Shown")),
            ("extends", None),
            ("inspired-by", Some("Shown")),
        ] {
            let with_footer = format!("{person}{FOOTER}");
            let got = insert_link_into_markdown(&with_footer, "Foo", kind, label);
            let want = format!(
                "{}{FOOTER}",
                insert_link_into_markdown(person, "Foo", kind, label)
            );
            assert_eq!(got, want, "{kind} {label:?} into {person:?}");
        }
    }

    // A marker inside fenced code is body text: the link goes after it.
    let fenced = format!("Code:\n```\n{M}\n```\n");
    assert_eq!(
        insert_link_into_markdown(&fenced, "Foo", "references", None),
        format!("{fenced}\n## Auto-added links\n\n[[Foo]]\n")
    );
    // The first marker outside the fence is the footer.
    let both = format!("{fenced}After.\n{FOOTER}");
    assert_eq!(
        insert_link_into_markdown(&both, "Foo", "references", None),
        format!("{fenced}After.\n\n## Auto-added links\n\n[[Foo]]\n{FOOTER}")
    );
}

#[test]
fn add_link_on_a_note_with_a_footer_keeps_the_link_above_the_marker() {
    let dir = tempfile::tempdir().unwrap();
    let mut vault = Vault::create(dir.path()).unwrap();
    let chip = create(&mut vault, "Player Loop", "About.\n", Some("topic"));
    let foo = create(&mut vault, "Foo", "Foo body.\n", None);
    let source = create(&mut vault, "Notes", "Notes.\n", None);
    give_footer(&mut vault, &source, &chip);

    let out = ops::add_link(
        &mut vault,
        AddLinkInput {
            from: source.id.to_string(),
            to: foo.id.to_string(),
            kind: "references".into(),
            label: None,
        },
        &SystemClock,
        None,
    )
    .expect("ops add_link");
    assert!(!out.was_existing);
    assert_eq!(
        stored(&vault, &source.id).content_md,
        format!("Notes.\n\n## Auto-added links\n\n[[Foo]]\n{FOOTER}")
    );
    assert_eq!(link_count(&vault, &source.id, &foo.id), 1);
}

#[tokio::test]
async fn mcp_add_link_on_a_note_with_a_footer_keeps_the_link_above_the_marker() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("vault");
    let vault = Vault::create(&path).unwrap();
    let state = Arc::new(AppState::new(vault, path, None));
    let memex = Memex::new(state.clone());
    let (source, foo) = {
        let mut v = state.vault.lock().await;
        let chip = create(&mut v, "Player Loop", "About.\n", Some("topic"));
        let foo = create(&mut v, "Foo", "Foo body.\n", None);
        let source = create(&mut v, "Notes", "Notes.\n", Some("topic"));
        give_footer(&mut v, &source, &chip);
        (source, foo)
    };

    let args = json!({ "from_id": source.id.to_string(), "to_id": foo.id.to_string() });
    let resp = memex
        .add_link(Parameters(serde_json::from_value(args).unwrap()))
        .await;
    let resp: Value = serde_json::from_str(&resp).unwrap_or_else(|e| panic!("{e}: {resp}"));
    assert!(resp.get("error").is_none(), "{resp}");

    let v = state.vault.lock().await;
    assert_eq!(
        stored(&v, &source.id).content_md,
        format!("Notes.\n\n## Auto-added links\n\n[[Foo]]\n{FOOTER}")
    );
    assert_eq!(link_count(&v, &source.id, &foo.id), 1);
}
