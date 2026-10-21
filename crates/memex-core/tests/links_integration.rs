//! Integration tests for the wikilinks pipeline. Real SQLite, real schema,
//! real indexer. No mocks — these prove the link rows are actually written
//! and resolved correctly.

use memex_core::error::MemexError;
use memex_core::indexer;
use memex_core::links::{self, LinkKind, LinkSource};
use memex_core::notes::{
    create_note, update_note, update_note_with_options, CreateNote, RenameOptions, UpdateNote,
};
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
fn title_rename_rewrites_wikilinks_in_linkers_transactionally() {
    let (_dir, mut vault) = fresh_vault();

    // Target whose title we will rename.
    let target = create_note(
        &mut vault,
        CreateNote {
            title: Some("Old Title".into()),
            content_md: "I am the target".into(),
            ..Default::default()
        },
    )
    .unwrap();
    indexer::reindex_note(vault.connection_mut(), target.id.as_str(), "I am the target", None)
        .unwrap();

    // Linker note that references the target in body + frontmatter.
    let linker_body =
        "---\nextends: [[Old Title]]\n---\n# Source\n\nSee [[Old Title]] and [[Old Title~contradicts]] and [[Old Title|aliased]].";
    let linker = create_note(
        &mut vault,
        CreateNote {
            title: Some("Linker".into()),
            content_md: linker_body.into(),
            ..Default::default()
        },
    )
    .unwrap();
    indexer::reindex_note(vault.connection_mut(), linker.id.as_str(), linker_body, None).unwrap();

    // Rename the target.
    let renamed = update_note(
        &mut vault,
        &target.id,
        target.version,
        UpdateNote {
            title: Some("New Title".into()),
            ..Default::default()
        },
    )
    .unwrap();
    assert_eq!(renamed.title, "New Title");

    // Linker's content was rewritten in body and frontmatter.
    let updated_linker_content: String = vault
        .connection_ref()
        .query_row(
            "SELECT content_md FROM notes WHERE id = ?",
            params![linker.id.as_str()],
            |r| r.get(0),
        )
        .unwrap();
    assert!(updated_linker_content.contains("[[New Title]]"));
    assert!(updated_linker_content.contains("[[New Title~contradicts]]"));
    assert!(updated_linker_content.contains("[[New Title|aliased]]"));
    assert!(!updated_linker_content.contains("[[Old Title"));

    // Linker's links rows were re-indexed and resolve to the renamed target.
    let outgoing = links::links_out_for_note(&vault, linker.id.as_str()).unwrap();
    for l in &outgoing {
        assert_eq!(l.link_text, "New Title");
        assert_eq!(l.to_note_id.as_deref(), Some(target.id.as_str()));
    }
}

#[test]
fn title_rename_rejects_collision_without_modifying_anything() {
    let (_dir, mut vault) = fresh_vault();
    let a = create_note(
        &mut vault,
        CreateNote {
            title: Some("Foo".into()),
            content_md: "a".into(),
            ..Default::default()
        },
    )
    .unwrap();
    let _b = create_note(
        &mut vault,
        CreateNote {
            title: Some("Bar".into()),
            content_md: "b".into(),
            ..Default::default()
        },
    )
    .unwrap();

    let err = update_note(
        &mut vault,
        &a.id,
        a.version,
        UpdateNote {
            title: Some("Bar".into()),
            ..Default::default()
        },
    )
    .unwrap_err();
    matches!(err, MemexError::TitleConflict { .. });

    // a's title unchanged.
    let after = vault
        .connection_ref()
        .query_row(
            "SELECT title FROM notes WHERE id = ?",
            params![a.id.as_str()],
            |r| r.get::<_, String>(0),
        )
        .unwrap();
    assert_eq!(after, "Foo");
}

#[test]
fn title_rename_with_no_rename_links_skips_linker_rewrite() {
    let (_dir, mut vault) = fresh_vault();

    let target = create_note(
        &mut vault,
        CreateNote {
            title: Some("Old".into()),
            content_md: "x".into(),
            ..Default::default()
        },
    )
    .unwrap();
    indexer::reindex_note(vault.connection_mut(), target.id.as_str(), "x", None).unwrap();

    let linker_body = "Linking [[Old]] here";
    let linker = create_note(
        &mut vault,
        CreateNote {
            title: Some("Linker".into()),
            content_md: linker_body.into(),
            ..Default::default()
        },
    )
    .unwrap();
    indexer::reindex_note(vault.connection_mut(), linker.id.as_str(), linker_body, None).unwrap();

    update_note_with_options(
        &mut vault,
        &target.id,
        target.version,
        UpdateNote {
            title: Some("New".into()),
            ..Default::default()
        },
        RenameOptions { rename_links: false },
    )
    .unwrap();

    let untouched: String = vault
        .connection_ref()
        .query_row(
            "SELECT content_md FROM notes WHERE id = ?",
            params![linker.id.as_str()],
            |r| r.get(0),
        )
        .unwrap();
    assert_eq!(untouched, linker_body);
}

#[test]
fn title_rename_rejects_invalid_title_chars() {
    let (_dir, mut vault) = fresh_vault();
    let a = create_note(
        &mut vault,
        CreateNote {
            title: Some("Foo".into()),
            content_md: "a".into(),
            ..Default::default()
        },
    )
    .unwrap();

    for bad in ["With~Tilde", "With|Pipe", "With]Bracket", "  leading", ""] {
        let err = update_note(
            &mut vault,
            &a.id,
            a.version,
            UpdateNote {
                title: Some(bad.into()),
                ..Default::default()
            },
        )
        .unwrap_err();
        assert!(matches!(err, MemexError::TitleInvalid(_)), "bad title was accepted: {bad:?}");
    }
}

// ---------- update_link ----------

fn place_source_with_target(content: &str) -> (tempfile::TempDir, Vault, String) {
    let (dir, mut vault) = fresh_vault();
    let _target = create_note(
        &mut vault,
        CreateNote {
            title: Some("Target".into()),
            content_md: "# Target\n".into(),
            ..Default::default()
        },
    )
    .unwrap();
    let src = create_note(
        &mut vault,
        CreateNote {
            title: Some("Source".into()),
            content_md: content.into(),
            ..Default::default()
        },
    )
    .unwrap();
    indexer::reindex_note(vault.connection_mut(), src.id.as_str(), content, None).unwrap();
    let src_id = src.id.as_str().to_string();
    (dir, vault, src_id)
}

#[test]
fn update_link_adds_kind_to_plain_wikilink() {
    let (_dir, mut vault, src) = place_source_with_target("Hello [[Target]] world.");
    let link = &links::links_out_for_note(&vault, &src).unwrap()[0];
    let link_id = link.id.clone();
    assert_eq!(link.link_kind.as_str(), "references");

    let updated = links::update_link(
        &mut vault,
        &link_id,
        links::UpdateLink {
            new_kind: Some(LinkKind::new("extends").unwrap()),
            new_label: None,
        },
    )
    .unwrap();
    assert_eq!(updated.link_kind.as_str(), "extends");

    let body: String = vault
        .connection_ref()
        .query_row(
            "SELECT content_md FROM notes WHERE id = ?",
            [&src],
            |r| r.get(0),
        )
        .unwrap();
    assert!(body.contains("[[Target~extends]]"), "{body:?}");
    assert!(!body.contains("[[Target]]"), "{body:?}");
}

#[test]
fn update_link_changes_kind_on_already_typed_wikilink() {
    let (_dir, mut vault, src) = place_source_with_target("Hello [[Target~extends]] world.");
    let link = &links::links_out_for_note(&vault, &src).unwrap()[0];
    let link_id = link.id.clone();

    links::update_link(
        &mut vault,
        &link_id,
        links::UpdateLink {
            new_kind: Some(LinkKind::new("contradicts").unwrap()),
            new_label: None,
        },
    )
    .unwrap();

    let body: String = vault
        .connection_ref()
        .query_row(
            "SELECT content_md FROM notes WHERE id = ?",
            [&src],
            |r| r.get(0),
        )
        .unwrap();
    assert!(body.contains("[[Target~contradicts]]"), "{body:?}");
    assert!(!body.contains("[[Target~extends]]"), "{body:?}");
}

#[test]
fn update_link_sets_label_preserving_kind() {
    let (_dir, mut vault, src) = place_source_with_target("[[Target~extends]] alone.");
    let link = &links::links_out_for_note(&vault, &src).unwrap()[0];
    let link_id = link.id.clone();

    links::update_link(
        &mut vault,
        &link_id,
        links::UpdateLink {
            new_kind: None,
            new_label: Some(Some("the target".into())),
        },
    )
    .unwrap();

    let body: String = vault
        .connection_ref()
        .query_row(
            "SELECT content_md FROM notes WHERE id = ?",
            [&src],
            |r| r.get(0),
        )
        .unwrap();
    assert!(body.contains("[[Target~extends|the target]]"), "{body:?}");
}

#[test]
fn update_link_clears_label() {
    let (_dir, mut vault, src) =
        place_source_with_target("[[Target~extends|alias here]] alone.");
    let link = &links::links_out_for_note(&vault, &src).unwrap()[0];
    let link_id = link.id.clone();
    assert_eq!(link.label.as_deref(), Some("alias here"));

    let updated = links::update_link(
        &mut vault,
        &link_id,
        links::UpdateLink {
            new_kind: None,
            new_label: Some(None),
        },
    )
    .unwrap();
    assert!(updated.label.is_none());

    let body: String = vault
        .connection_ref()
        .query_row(
            "SELECT content_md FROM notes WHERE id = ?",
            [&src],
            |r| r.get(0),
        )
        .unwrap();
    assert!(body.contains("[[Target~extends]]"), "{body:?}");
    assert!(!body.contains("alias here"), "{body:?}");
}

#[test]
fn update_link_sets_both_kind_and_label_starting_from_plain() {
    let (_dir, mut vault, src) = place_source_with_target("plain [[Target]] here.");
    let link = &links::links_out_for_note(&vault, &src).unwrap()[0];
    let link_id = link.id.clone();

    links::update_link(
        &mut vault,
        &link_id,
        links::UpdateLink {
            new_kind: Some(LinkKind::new("inspired-by").unwrap()),
            new_label: Some(Some("the muse".into())),
        },
    )
    .unwrap();

    let body: String = vault
        .connection_ref()
        .query_row(
            "SELECT content_md FROM notes WHERE id = ?",
            [&src],
            |r| r.get(0),
        )
        .unwrap();
    assert!(body.contains("[[Target~inspired-by|the muse]]"), "{body:?}");
}

#[test]
fn update_link_noop_returns_current_link_unchanged() {
    let (_dir, mut vault, src) = place_source_with_target("[[Target~extends]]");
    let link = links::links_out_for_note(&vault, &src).unwrap()[0].clone();
    let result = links::update_link(
        &mut vault,
        &link.id,
        links::UpdateLink::default(),
    )
    .unwrap();
    assert_eq!(result.id, link.id);
    assert_eq!(result.link_kind.as_str(), "extends");
}

#[test]
fn update_link_rejects_unknown_link_id() {
    let (_dir, mut vault) = fresh_vault();
    let err = links::update_link(
        &mut vault,
        "nonexistent-link-id",
        links::UpdateLink {
            new_kind: Some(LinkKind::new("extends").unwrap()),
            new_label: None,
        },
    )
    .unwrap_err();
    assert!(matches!(err, MemexError::NotFound(_)), "got {err:?}");
}

#[test]
fn update_link_on_frontmatter_link_rejects_kind_change() {
    let (_dir, mut vault) = fresh_vault();
    let _target = create_note(
        &mut vault,
        CreateNote {
            title: Some("Target".into()),
            content_md: "# Target\n".into(),
            ..Default::default()
        },
    )
    .unwrap();
    let content = "---\nextends:\n  - [[Target]]\n---\n# Source\n";
    let src = create_note(
        &mut vault,
        CreateNote {
            title: Some("Source".into()),
            content_md: content.into(),
            ..Default::default()
        },
    )
    .unwrap();
    indexer::reindex_note(vault.connection_mut(), src.id.as_str(), content, None).unwrap();

    let link = &links::links_out_for_note(&vault, src.id.as_str()).unwrap()[0];
    assert_eq!(link.source, LinkSource::Frontmatter);
    let err = links::update_link(
        &mut vault,
        &link.id,
        links::UpdateLink {
            new_kind: Some(LinkKind::new("contradicts").unwrap()),
            new_label: None,
        },
    )
    .unwrap_err();
    assert!(matches!(err, MemexError::InvalidLinkKind(_)), "got {err:?}");
}

#[test]
fn update_link_on_frontmatter_link_supports_label_change() {
    let (_dir, mut vault) = fresh_vault();
    let _target = create_note(
        &mut vault,
        CreateNote {
            title: Some("Target".into()),
            content_md: "# Target\n".into(),
            ..Default::default()
        },
    )
    .unwrap();
    let content = "---\nextends:\n  - [[Target]]\n---\n# Source\n";
    let src = create_note(
        &mut vault,
        CreateNote {
            title: Some("Source".into()),
            content_md: content.into(),
            ..Default::default()
        },
    )
    .unwrap();
    indexer::reindex_note(vault.connection_mut(), src.id.as_str(), content, None).unwrap();

    let link = links::links_out_for_note(&vault, src.id.as_str()).unwrap()[0].clone();
    let updated = links::update_link(
        &mut vault,
        &link.id,
        links::UpdateLink {
            new_kind: None,
            new_label: Some(Some("Tee".into())),
        },
    )
    .unwrap();
    assert_eq!(updated.label.as_deref(), Some("Tee"));

    let body: String = vault
        .connection_ref()
        .query_row(
            "SELECT content_md FROM notes WHERE id = ?",
            [src.id.as_str()],
            |r| r.get(0),
        )
        .unwrap();
    assert!(body.contains("[[Target|Tee]]"), "{body:?}");
    // No `~kind` infix in the YAML wikilink.
    assert!(!body.contains("[[Target~"), "{body:?}");
}

#[test]
fn schema_v3_migration_is_idempotent_on_fresh_vault() {
    let (_dir, vault) = fresh_vault();
    let v: i64 = vault
        .connection_ref()
        .query_row("SELECT MAX(version) FROM schema_version", [], |r| r.get(0))
        .unwrap();
    assert_eq!(v, memex_core::schema::APP_SCHEMA_VERSION);

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

// ---------- WI #141: frontmatter positions stay unique ----------

/// A `Target` note plus a `Source` note holding `content`, both saved. The
/// source is NOT indexed, so the caller sees the reindex result.
fn wi141_source_and_target(content: &str) -> (tempfile::TempDir, Vault, String) {
    let (dir, mut vault) = fresh_vault();
    create_note(
        &mut vault,
        CreateNote {
            title: Some("Target".into()),
            content_md: "# Target\n".into(),
            ..Default::default()
        },
    )
    .unwrap();
    let src = create_note(
        &mut vault,
        CreateNote {
            title: Some("Source".into()),
            content_md: content.into(),
            ..Default::default()
        },
    )
    .unwrap();
    (dir, vault, src.id.as_str().to_string())
}

fn wi141_content_and_version(vault: &Vault, id: &str) -> (String, i64) {
    vault
        .connection_ref()
        .query_row(
            "SELECT content_md, version FROM notes WHERE id = ?",
            [id],
            |r| Ok((r.get(0)?, r.get(1)?)),
        )
        .unwrap()
}

/// `(kind, position, label)` of every outgoing link, by position.
fn wi141_links(vault: &Vault, id: &str) -> Vec<(String, i64, Option<String>)> {
    links::links_out_for_note(vault, id)
        .unwrap()
        .into_iter()
        .map(|l| (l.link_kind.as_str().to_string(), l.position, l.label))
        .collect()
}

fn wi141_offsets(md: &str, needle: &str) -> Vec<i64> {
    md.match_indices(needle).map(|(i, _)| i as i64).collect()
}

#[test]
fn reindex_indexes_same_wikilink_under_two_frontmatter_kind_keys() {
    let content = "---\nnotes: see [[Target]]\nextends:\n  - [[Target]]\n---\nbody\n";
    let (_dir, mut vault, src) = wi141_source_and_target(content);

    indexer::reindex_note(vault.connection_mut(), &src, content, None)
        .expect("a note repeating a wikilink under two kind keys must index");

    let at = wi141_offsets(content, "[[Target]]");
    assert_eq!(
        wi141_links(&vault, &src),
        vec![
            ("notes".to_string(), at[0], None),
            ("extends".to_string(), at[1], None),
        ]
    );
}

#[test]
fn reindex_indexes_repeated_token_under_one_key_at_successive_offsets() {
    let content = "---\nextends:\n  - [[Target]]\n  - [[Target]]\n---\nbody\n";
    let (_dir, mut vault, src) = wi141_source_and_target(content);

    indexer::reindex_note(vault.connection_mut(), &src, content, None)
        .expect("two identical tokens under one key must index");

    let at = wi141_offsets(content, "[[Target]]");
    assert_eq!(
        wi141_links(&vault, &src),
        vec![
            ("extends".to_string(), at[0], None),
            ("extends".to_string(), at[1], None),
        ]
    );
}

#[test]
fn update_link_label_below_skipped_about_key_rewrites_only_its_own_token() {
    let content = "---\nabout: [[Target]]\nextends:\n  - [[Target]]\n---\n# Source\n";
    let (_dir, mut vault, src) = wi141_source_and_target(content);
    indexer::reindex_note(vault.connection_mut(), &src, content, None).unwrap();

    let own = content.rfind("[[Target]]").unwrap() as i64;
    let link = links::links_out_for_note(&vault, &src).unwrap()[0].clone();
    assert_eq!(link.link_kind.as_str(), "extends");
    assert_eq!(link.position, own, "the extends link sits at its own token");

    let updated = links::update_link(
        &mut vault,
        &link.id,
        links::UpdateLink {
            new_kind: None,
            new_label: Some(Some("X".into())),
        },
    )
    .expect("update-link on the extends link succeeds");
    assert_eq!(updated.label.as_deref(), Some("X"));
    assert_eq!(updated.position, own);

    let (body, _) = wi141_content_and_version(&vault, &src);
    assert_eq!(
        body,
        "---\nabout: [[Target]]\nextends:\n  - [[Target|X]]\n---\n# Source\n"
    );
    assert_eq!(
        wi141_links(&vault, &src),
        vec![("extends".to_string(), own, Some("X".to_string()))]
    );
}

#[test]
fn update_link_on_frontmatter_token_without_verbatim_occurrence_is_not_found() {
    // `\x5B\x5BTarget]]` decodes to `[[Target]]` but never appears verbatim.
    let content =
        "---\nextends: \"\\x5B\\x5BTarget]]\"\ncontradicts:\n  - [[Target]]\n---\n# Source\n";
    let (_dir, mut vault, src) = wi141_source_and_target(content);
    indexer::reindex_note(vault.connection_mut(), &src, content, None)
        .expect("an escaped token next to a verbatim one must index");

    let all = links::links_out_for_note(&vault, &src).unwrap();
    assert_eq!(all.len(), 2, "{all:?}");
    let contradicts = all
        .iter()
        .find(|l| l.link_kind.as_str() == "contradicts")
        .unwrap();
    assert_eq!(
        contradicts.position,
        content.find("[[Target]]").unwrap() as i64
    );
    let escaped = all
        .iter()
        .find(|l| l.link_kind.as_str() == "extends")
        .unwrap()
        .clone();
    assert_ne!(escaped.position, contradicts.position);

    let before = wi141_content_and_version(&vault, &src);
    let links_before = wi141_links(&vault, &src);
    let err = links::update_link(
        &mut vault,
        &escaped.id,
        links::UpdateLink {
            new_kind: None,
            new_label: Some(Some("X".into())),
        },
    )
    .unwrap_err();
    assert!(matches!(err, MemexError::NotFound(_)), "got {err:?}");
    assert_eq!(wi141_content_and_version(&vault, &src), before);
    assert_eq!(wi141_links(&vault, &src), links_before);
}

#[test]
fn next_save_of_note_left_with_repeated_tokens_reindexes_links_and_fts() {
    // The state a failed reindex leaves on main: the note's content holds two
    // identical frontmatter tokens, but its index is stale (never written).
    let stale = "---\nextends:\n  - [[Target]]\ncontradicts:\n  - [[Target]]\n---\nold\n";
    let (_dir, mut vault, src) = wi141_source_and_target(stale);
    let (_, version) = wi141_content_and_version(&vault, &src);

    let next = "---\nextends:\n  - [[Target]]\ncontradicts:\n  - [[Target]]\n---\nzebrafinch\n";
    let saved = update_note(
        &mut vault,
        &memex_core::notes::NoteId::parse(&src).unwrap(),
        version,
        UpdateNote {
            content_md: Some(next.into()),
            ..Default::default()
        },
    )
    .unwrap();
    indexer::reindex_note(vault.connection_mut(), &src, &saved.content_md, None)
        .expect("the next save reindexes cleanly, with no migration");

    let at = wi141_offsets(next, "[[Target]]");
    assert_eq!(
        wi141_links(&vault, &src),
        vec![
            ("extends".to_string(), at[0], None),
            ("contradicts".to_string(), at[1], None),
        ]
    );
    let hits: i64 = vault
        .connection_ref()
        .query_row(
            "SELECT COUNT(*) FROM chunk_fts WHERE note_id = ? AND chunk_fts MATCH 'zebrafinch'",
            params![src],
            |r| r.get(0),
        )
        .unwrap();
    assert!(hits > 0, "FTS holds the saved content");
}

// ---------- WI #145: frontmatter keeps non-ASCII text ----------

/// Notes titled `targets`, then a `Source` note holding `content`, all saved.
/// Returns the target ids in order and the source id; the source is NOT
/// indexed, so the caller sees the reindex result.
fn wi145_notes(targets: &[&str], content: &str) -> (tempfile::TempDir, Vault, Vec<String>, String) {
    let (dir, mut vault) = fresh_vault();
    let mut ids = Vec::new();
    for t in targets {
        let n = create_note(
            &mut vault,
            CreateNote {
                title: Some((*t).into()),
                content_md: format!("# {t}\n"),
                ..Default::default()
            },
        )
        .unwrap();
        ids.push(n.id.as_str().to_string());
    }
    let src = create_note(
        &mut vault,
        CreateNote {
            title: Some("Source".into()),
            content_md: content.into(),
            ..Default::default()
        },
    )
    .unwrap();
    (dir, vault, ids, src.id.as_str().to_string())
}

fn wi145_parse_error_flag(vault: &Vault, id: &str) -> i64 {
    vault
        .connection_ref()
        .query_row(
            "SELECT frontmatter_parse_error FROM notes WHERE id = ?",
            [id],
            |r| r.get(0),
        )
        .unwrap()
}

/// `(kind, link_text, label, to_note_id, position)` of every outgoing link,
/// by position.
type Wi145Row = (String, String, Option<String>, Option<String>, i64);

fn wi145_rows(vault: &Vault, id: &str) -> Vec<Wi145Row> {
    let mut rows: Vec<Wi145Row> = links::links_out_for_note(vault, id)
        .unwrap()
        .into_iter()
        .map(|l| {
            (
                l.link_kind.as_str().to_string(),
                l.link_text,
                l.label,
                l.to_note_id,
                l.position,
            )
        })
        .collect();
    rows.sort_by_key(|r| r.4);
    rows
}

/// A resolved link row, as [`wi145_rows`] returns it.
fn wi145_row(kind: &str, text: &str, label: Option<&str>, to: &str, position: i64) -> Wi145Row {
    (
        kind.to_string(),
        text.to_string(),
        label.map(str::to_string),
        Some(to.to_string()),
        position,
    )
}

fn wi145_token_starts(md: &str) -> Vec<i64> {
    md.match_indices("[[").map(|(i, _)| i as i64).collect()
}

#[test]
fn reindex_note_with_non_ascii_title_has_no_parse_error_and_indexes_extends_link() {
    let content = "---\ntitle: Ünïcødé\nextends:\n  - [[Alpha]]\n---\nbody\n";
    let (_dir, mut vault, ids, src) = wi145_notes(&["Alpha"], content);

    indexer::reindex_note(vault.connection_mut(), &src, content, None).unwrap();

    assert_eq!(
        wi145_parse_error_flag(&vault, &src),
        0,
        "a non-ASCII title must not set frontmatter_parse_error"
    );
    assert_eq!(
        wi145_rows(&vault, &src),
        vec![(
            "extends".to_string(),
            "Alpha".to_string(),
            None,
            Some(ids[0].clone()),
            content.find("[[Alpha]]").unwrap() as i64,
        )]
    );
}

#[test]
fn reindex_resolves_bare_and_quoted_non_ascii_token_titles_to_their_notes() {
    let content = "---\nextends: [[Café]]\ncontradicts:\n  - [[日本語]]\n\
                   example-of: \"[[Café]]\"\ninspired-by: '[[日本語]]'\n---\nbody\n";
    let (_dir, mut vault, ids, src) = wi145_notes(&["Café", "日本語"], content);

    indexer::reindex_note(vault.connection_mut(), &src, content, None).unwrap();

    assert_eq!(wi145_parse_error_flag(&vault, &src), 0);
    let at = wi145_token_starts(content);
    let (cafe, nihongo) = (&ids[0], &ids[1]);
    assert_eq!(
        wi145_rows(&vault, &src),
        vec![
            wi145_row("extends", "Café", None, cafe, at[0]),
            wi145_row("contradicts", "日本語", None, nihongo, at[1]),
            wi145_row("example-of", "Café", None, cafe, at[2]),
            wi145_row("inspired-by", "日本語", None, nihongo, at[3]),
        ]
    );
}

#[test]
fn reindex_round_trips_non_ascii_frontmatter_label_to_links_label() {
    let label = "Ünïcode – dash";
    let content = "---\nextends: [[Alpha|Ünïcode – dash]]\n\
                   contradicts: \"[[Alpha|Ünïcode – dash]]\"\n---\nbody\n";
    let (_dir, mut vault, ids, src) = wi145_notes(&["Alpha"], content);

    indexer::reindex_note(vault.connection_mut(), &src, content, None).unwrap();

    let at = wi145_token_starts(content);
    assert_eq!(
        wi145_rows(&vault, &src),
        vec![
            wi145_row("extends", "Alpha", Some(label), &ids[0], at[0]),
            wi145_row("contradicts", "Alpha", Some(label), &ids[0], at[1]),
        ]
    );
}

#[test]
fn update_link_writes_non_ascii_label_into_quoted_frontmatter_token_and_links_label() {
    let content = "---\nsummary: \"Crème brûlée\"\nextends: \"[[Alpha]]\"\n---\n# Source\n";
    let (_dir, mut vault, ids, src) = wi145_notes(&["Alpha"], content);
    indexer::reindex_note(vault.connection_mut(), &src, content, None).unwrap();
    let rows = links::links_out_for_note(&vault, &src).unwrap();
    assert_eq!(rows.len(), 1, "the quoted token indexes: {rows:?}");
    let own = content.find("[[Alpha]]").unwrap() as i64;

    let updated = links::update_link(
        &mut vault,
        &rows[0].id,
        links::UpdateLink {
            new_kind: None,
            new_label: Some(Some("Ünïcode – dash 😀".into())),
        },
    )
    .expect("update-link with a non-ASCII label succeeds");
    assert_eq!(updated.label.as_deref(), Some("Ünïcode – dash 😀"));

    let (body, _) = wi141_content_and_version(&vault, &src);
    assert_eq!(
        body,
        "---\nsummary: \"Crème brûlée\"\nextends: \"[[Alpha|Ünïcode – dash 😀]]\"\n---\n# Source\n"
    );
    assert_eq!(wi145_parse_error_flag(&vault, &src), 0);
    assert_eq!(
        wi145_rows(&vault, &src),
        vec![(
            "extends".into(),
            "Alpha".into(),
            Some("Ünïcode – dash 😀".into()),
            Some(ids[0].clone()),
            own,
        )]
    );
}

#[test]
fn update_link_on_block_scalar_hash_line_token_is_not_found_and_leaves_note_unchanged() {
    // Pinned current behaviour (WI #141 open risk): a `|` block-scalar line
    // starting with `#` reads as a comment, so its token gets a past-the-end
    // position. update-link answers not_found and leaves the note untouched;
    // the next key's link keeps its own token.
    let content = "---\nextends: |\n  # [[Target]]\ncontradicts: [[Target]]\n---\n# Source\n";
    let (_dir, mut vault, src) = wi141_source_and_target(content);
    indexer::reindex_note(vault.connection_mut(), &src, content, None)
        .expect("a block scalar holding a `#` line must index");

    let all = links::links_out_for_note(&vault, &src).unwrap();
    assert_eq!(all.len(), 2, "{all:?}");
    let by_kind = |kind: &str| {
        all.iter()
            .find(|l| l.link_kind.as_str() == kind)
            .unwrap_or_else(|| panic!("no {kind} link: {all:?}"))
            .clone()
    };
    let contradicts = by_kind("contradicts");
    assert_eq!(
        contradicts.position,
        wi141_offsets(content, "[[Target]]")[1]
    );
    let block = by_kind("extends");
    assert_eq!(block.position, content.len() as i64);

    let before = wi141_content_and_version(&vault, &src);
    let links_before = wi141_links(&vault, &src);
    let err = links::update_link(
        &mut vault,
        &block.id,
        links::UpdateLink {
            new_kind: None,
            new_label: Some(Some("X".into())),
        },
    )
    .unwrap_err();
    assert!(matches!(err, MemexError::NotFound(_)), "got {err:?}");
    assert_eq!(wi141_content_and_version(&vault, &src), before);
    assert_eq!(wi141_links(&vault, &src), links_before);
}
