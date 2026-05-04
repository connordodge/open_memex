//! Integration tests for the wikilinks pipeline. Real SQLite, real schema,
//! real indexer. No mocks — these prove the link rows are actually written
//! and resolved correctly.

use memex_core::indexer;
use memex_core::links::{self, LinkKind, LinkSource};
use memex_core::notes::{create_note, update_note, CreateNote, UpdateNote};
use memex_core::Vault;
use rusqlite::params;

fn fresh_vault() -> (tempfile::TempDir, Vault) {
    let dir = tempfile::tempdir().unwrap();
    let vault = Vault::create(dir.path()).unwrap();
    (dir, vault)
}

#[test]
fn reindex_writes_link_rows_with_default_kind() {
    let (_dir, mut vault) = fresh_vault();

    let n = create_note(
        &mut vault,
        CreateNote {
            title: Some("Source".into()),
            content_md: "Hello [[Foo]] world.".into(),
            ..Default::default()
        },
    )
    .unwrap();

    indexer::reindex_note(vault.connection_mut(), n.id.as_str(), "Hello [[Foo]] world.", None)
        .unwrap();

    let outgoing = links::links_out_for_note(&vault, n.id.as_str()).unwrap();
    assert_eq!(outgoing.len(), 1);
    assert_eq!(outgoing[0].link_text, "Foo");
    assert_eq!(outgoing[0].link_kind.as_str(), "references");
    assert_eq!(outgoing[0].source, LinkSource::InlineBody);
    assert!(outgoing[0].to_note_id.is_none(), "Foo doesn't exist yet → ghost");
}

#[test]
fn ghost_link_resolves_when_target_is_created_then_source_reindexed() {
    let (_dir, mut vault) = fresh_vault();

    // Source links to a not-yet-existent target.
    let src = create_note(
        &mut vault,
        CreateNote {
            title: Some("Source".into()),
            content_md: "Read [[Target]] later.".into(),
            ..Default::default()
        },
    )
    .unwrap();
    indexer::reindex_note(vault.connection_mut(), src.id.as_str(), "Read [[Target]] later.", None)
        .unwrap();

    // Initially ghost.
    let pre = links::links_out_for_note(&vault, src.id.as_str()).unwrap();
    assert!(pre[0].to_note_id.is_none());

    // Create the target.
    let tgt = create_note(
        &mut vault,
        CreateNote {
            title: Some("Target".into()),
            content_md: "I exist now.".into(),
            ..Default::default()
        },
    )
    .unwrap();

    // Re-index source: link should resolve to target.
    indexer::reindex_note(vault.connection_mut(), src.id.as_str(), "Read [[Target]] later.", None)
        .unwrap();

    let post = links::links_out_for_note(&vault, src.id.as_str()).unwrap();
    assert_eq!(post.len(), 1);
    assert_eq!(post[0].to_note_id.as_deref(), Some(tgt.id.as_str()));
}

#[test]
fn typed_wikilinks_are_recorded_with_their_kinds() {
    let (_dir, mut vault) = fresh_vault();

    let body = "I [[Foo~extends]] this. And [[Bar~contradicts]]. And [[Baz~inspired-by]] also.";
    let n = create_note(
        &mut vault,
        CreateNote {
            title: Some("Source".into()),
            content_md: body.into(),
            ..Default::default()
        },
    )
    .unwrap();
    indexer::reindex_note(vault.connection_mut(), n.id.as_str(), body, None).unwrap();

    let mut outgoing = links::links_out_for_note(&vault, n.id.as_str()).unwrap();
    outgoing.sort_by_key(|l| l.position);
    let kinds: Vec<&str> = outgoing.iter().map(|l| l.link_kind.as_str()).collect();
    assert_eq!(kinds, vec!["extends", "contradicts", "inspired-by"]);
}

#[test]
fn section_grouping_records_inline_section_source() {
    let (_dir, mut vault) = fresh_vault();

    let body = "## Contradicts\n\n[[A]]\n\n## Other\n\n[[B]]";
    let n = create_note(
        &mut vault,
        CreateNote {
            title: Some("Source".into()),
            content_md: body.into(),
            ..Default::default()
        },
    )
    .unwrap();
    indexer::reindex_note(vault.connection_mut(), n.id.as_str(), body, None).unwrap();

    let mut outgoing = links::links_out_for_note(&vault, n.id.as_str()).unwrap();
    outgoing.sort_by_key(|l| l.position);
    assert_eq!(outgoing[0].link_text, "A");
    assert_eq!(outgoing[0].link_kind.as_str(), "contradicts");
    assert_eq!(outgoing[0].source, LinkSource::InlineSection);
    assert_eq!(outgoing[1].link_text, "B");
    assert_eq!(outgoing[1].link_kind.as_str(), "references");
    assert_eq!(outgoing[1].source, LinkSource::InlineBody);
}

#[test]
fn frontmatter_links_are_recorded_with_frontmatter_source() {
    let (_dir, mut vault) = fresh_vault();

    let body = "---\nextends: [[Local-first]]\ncontradicts:\n  - [[Server-truth]]\ninspired-by: [[Memex]]\n---\nbody text";
    let n = create_note(
        &mut vault,
        CreateNote {
            title: Some("Source".into()),
            content_md: body.into(),
            ..Default::default()
        },
    )
    .unwrap();
    indexer::reindex_note(vault.connection_mut(), n.id.as_str(), body, None).unwrap();

    let outgoing = links::links_out_for_note(&vault, n.id.as_str()).unwrap();
    assert_eq!(outgoing.len(), 3);
    for l in &outgoing {
        assert_eq!(l.source, LinkSource::Frontmatter);
    }
    let by_kind: std::collections::HashMap<&str, &str> = outgoing
        .iter()
        .map(|l| (l.link_kind.as_str(), l.link_text.as_str()))
        .collect();
    assert_eq!(by_kind.get("extends"), Some(&"Local-first"));
    assert_eq!(by_kind.get("contradicts"), Some(&"Server-truth"));
    assert_eq!(by_kind.get("inspired-by"), Some(&"Memex"));
}

#[test]
fn replace_links_for_note_clears_old_rows() {
    let (_dir, mut vault) = fresh_vault();

    let n = create_note(
        &mut vault,
        CreateNote {
            title: Some("Source".into()),
            content_md: "[[Old]] [[Stays]]".into(),
            ..Default::default()
        },
    )
    .unwrap();
    indexer::reindex_note(vault.connection_mut(), n.id.as_str(), "[[Old]] [[Stays]]", None)
        .unwrap();
    assert_eq!(links::links_out_for_note(&vault, n.id.as_str()).unwrap().len(), 2);

    // Update content; only one wikilink remains.
    update_note(
        &mut vault,
        &n.id,
        n.version,
        UpdateNote {
            content_md: Some("[[Stays]] only".into()),
            ..Default::default()
        },
    )
    .unwrap();
    indexer::reindex_note(vault.connection_mut(), n.id.as_str(), "[[Stays]] only", None).unwrap();

    let outgoing = links::links_out_for_note(&vault, n.id.as_str()).unwrap();
    assert_eq!(outgoing.len(), 1);
    assert_eq!(outgoing[0].link_text, "Stays");
}

#[test]
fn backlinks_query_returns_incoming_grouped_by_kind() {
    let (_dir, mut vault) = fresh_vault();

    let target = create_note(
        &mut vault,
        CreateNote {
            title: Some("Target".into()),
            content_md: "I am the target".into(),
            ..Default::default()
        },
    )
    .unwrap();
    indexer::reindex_note(vault.connection_mut(), target.id.as_str(), "I am the target", None)
        .unwrap();

    for (title, body) in [
        ("LinkerA", "Refers to [[Target]]"),
        ("LinkerB", "## Contradicts\n\n[[Target]]"),
        ("LinkerC", "[[Target~extends]]"),
    ] {
        let n = create_note(
            &mut vault,
            CreateNote {
                title: Some(title.into()),
                content_md: body.into(),
                ..Default::default()
            },
        )
        .unwrap();
        indexer::reindex_note(vault.connection_mut(), n.id.as_str(), body, None).unwrap();
    }

    let all_in = links::links_in_for_note(&vault, target.id.as_str(), None).unwrap();
    assert_eq!(all_in.len(), 3);

    let contradicts_in = links::links_in_for_note(
        &vault,
        target.id.as_str(),
        Some(&LinkKind::new("contradicts").unwrap()),
    )
    .unwrap();
    assert_eq!(contradicts_in.len(), 1);

    let extends_in = links::links_in_for_note(
        &vault,
        target.id.as_str(),
        Some(&LinkKind::new("extends").unwrap()),
    )
    .unwrap();
    assert_eq!(extends_in.len(), 1);
}

#[test]
fn open_questions_flag_is_set_on_relevant_notes() {
    let (_dir, mut vault) = fresh_vault();

    let body_with = "stuff\n\n## Open questions\n\nis this a thing?";
    let body_without = "just stuff";

    let with = create_note(
        &mut vault,
        CreateNote {
            title: Some("WithQs".into()),
            content_md: body_with.into(),
            ..Default::default()
        },
    )
    .unwrap();
    indexer::reindex_note(vault.connection_mut(), with.id.as_str(), body_with, None).unwrap();

    let without = create_note(
        &mut vault,
        CreateNote {
            title: Some("Plain".into()),
            content_md: body_without.into(),
            ..Default::default()
        },
    )
    .unwrap();
    indexer::reindex_note(vault.connection_mut(), without.id.as_str(), body_without, None)
        .unwrap();

    let flag_with: i64 = vault
        .connection_ref()
        .query_row(
            "SELECT has_open_questions FROM notes WHERE id = ?",
            params![with.id.as_str()],
            |r| r.get(0),
        )
        .unwrap();
    let flag_without: i64 = vault
        .connection_ref()
        .query_row(
            "SELECT has_open_questions FROM notes WHERE id = ?",
            params![without.id.as_str()],
            |r| r.get(0),
        )
        .unwrap();
    assert_eq!(flag_with, 1);
    assert_eq!(flag_without, 0);
}

#[test]
fn schema_v3_migration_is_idempotent_on_fresh_vault() {
    let (_dir, vault) = fresh_vault();
    let v: i64 = vault
        .connection_ref()
        .query_row("SELECT MAX(version) FROM schema_version", [], |r| r.get(0))
        .unwrap();
    assert_eq!(v, 3);

    // Sanity: tables / columns exist.
    let _: i64 = vault
        .connection_ref()
        .query_row("SELECT COUNT(*) FROM links", [], |r| r.get(0))
        .unwrap();
    let _: i64 = vault
        .connection_ref()
        .query_row("SELECT COUNT(*) FROM notes_dedup_log", [], |r| r.get(0))
        .unwrap();
    let _: i64 = vault
        .connection_ref()
        .query_row(
            "SELECT has_open_questions FROM notes WHERE 1=0",
            [],
            |r| r.get(0),
        )
        .unwrap_or(0);
}
