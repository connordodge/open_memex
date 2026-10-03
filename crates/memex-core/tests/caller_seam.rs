//! The caller seam (architect ruling D3): `Caller {Person, Agent}` and the
//! agent-aware entry points `notes::create_note_as`, `notes::update_note_as`
//! and `links::update_link_as`. Until later Work Items add agent rules, both
//! callers behave exactly like the existing person-path functions.
//!
//! Real SQLite, real schema, real indexer; each comparison runs the old and
//! the new entry point in separate fresh vaults on the same input.

use memex_core::error::MemexError;
use memex_core::indexer;
use memex_core::links::{self, LinkKind, UpdateLink};
use memex_core::notes::{
    self, create_note, get_note, update_note_with_options, CreateNote, Note, NoteId, RenameOptions,
    UpdateNote,
};
use memex_core::{Caller, Vault};
use serde_json::{json, Value};

const CALLERS: [Caller; 2] = [Caller::Person, Caller::Agent];

fn fresh_vault() -> (tempfile::TempDir, Vault) {
    let dir = tempfile::tempdir().unwrap();
    let vault = Vault::create(dir.path()).unwrap();
    (dir, vault)
}

/// The parts of a note that must match between the old and new entry points
/// (ids and timestamps differ by construction).
fn shape(n: &Note) -> (String, String, Value, i64) {
    (
        n.title.clone(),
        n.content_md.clone(),
        n.frontmatter.clone(),
        n.version,
    )
}

fn body_of(vault: &Vault, id: &str) -> String {
    get_note(vault, &NoteId::parse(id).unwrap())
        .unwrap()
        .content_md
}

fn version_of(vault: &Vault, id: &str) -> i64 {
    get_note(vault, &NoteId::parse(id).unwrap())
        .unwrap()
        .version
}

fn create_inputs() -> Vec<CreateNote> {
    vec![
        CreateNote {
            title: Some("Explicit Title".into()),
            content_md: "# Heading\n\nBody with [[Elsewhere]].".into(),
            frontmatter: Some(json!({"tags": ["a", "b"], "status": "draft"})),
        },
        CreateNote {
            title: None,
            content_md: "## Derived From First Line\nsecond line".into(),
            frontmatter: None,
        },
        CreateNote {
            title: None,
            content_md: String::new(),
            frontmatter: None,
        },
    ]
}

// ---------- AC1: Caller ----------

fn assert_copy_eq_debug<T: Copy + Eq + std::fmt::Debug>() {}

#[test]
fn caller_has_exactly_person_and_agent_and_is_copy_eq_debug() {
    assert_copy_eq_debug::<Caller>();
    // Same type from the module path and the crate root.
    let via_module: memex_core::caller::Caller = Caller::Agent;

    // No wildcard: a third variant would fail to compile here.
    fn label(c: Caller) -> &'static str {
        match c {
            Caller::Person => "person",
            Caller::Agent => "agent",
        }
    }
    assert_eq!(label(Caller::Person), "person");
    assert_eq!(label(via_module), "agent");

    let p = Caller::Person;
    let copied = p; // Copy: `p` stays usable.
    assert_eq!(p, copied);
    assert_ne!(Caller::Person, Caller::Agent);
    assert_eq!(format!("{:?}", Caller::Person), "Person");
    assert_eq!(format!("{:?}", Caller::Agent), "Agent");
}

// ---------- AC2: create_note_as ----------

#[test]
fn create_note_as_matches_create_note_for_both_callers() {
    for input in create_inputs() {
        let (_d0, mut v0) = fresh_vault();
        let baseline = create_note(&mut v0, input.clone()).unwrap();
        assert_eq!(baseline.version, 1);

        for caller in CALLERS {
            let (_d, mut v) = fresh_vault();
            let created = notes::create_note_as(&mut v, input.clone(), caller).unwrap();
            assert_eq!(shape(&created), shape(&baseline), "{caller:?} on {input:?}");
            // And what was persisted is what was returned.
            let stored = get_note(&v, &created.id).unwrap();
            assert_eq!(shape(&stored), shape(&baseline), "{caller:?} stored");
        }
    }
}

#[test]
fn create_note_as_fails_on_a_taken_title_like_create_note() {
    let taken = CreateNote {
        title: Some("Taken".into()),
        content_md: "first".into(),
        frontmatter: None,
    };
    let (_d0, mut v0) = fresh_vault();
    create_note(&mut v0, taken.clone()).unwrap();
    let baseline_err = create_note(&mut v0, taken.clone()).unwrap_err();

    for caller in CALLERS {
        let (_d, mut v) = fresh_vault();
        create_note(&mut v, taken.clone()).unwrap();
        let err = notes::create_note_as(&mut v, taken.clone(), caller).unwrap_err();
        assert_eq!(err.code(), baseline_err.code(), "{caller:?}: {err}");
        let count: i64 = v
            .connection_ref()
            .query_row("SELECT COUNT(*) FROM notes", [], |r| r.get(0))
            .unwrap();
        assert_eq!(count, 1, "{caller:?}: no second note written");
    }
}

// ---------- AC3: update_note_as ----------

#[test]
fn update_note_as_bumps_version_like_update_note_with_options() {
    let patches = [
        UpdateNote {
            content_md: Some("new body".into()),
            ..Default::default()
        },
        UpdateNote {
            frontmatter: Some(json!({"status": "done"})),
            ..Default::default()
        },
        UpdateNote {
            title: Some("Renamed".into()),
            content_md: Some("renamed body".into()),
            frontmatter: None,
        },
        UpdateNote::default(),
    ];
    let seed = CreateNote {
        title: Some("Seed".into()),
        content_md: "seed body".into(),
        frontmatter: Some(json!({"status": "draft"})),
    };

    for patch in patches {
        let (_d0, mut v0) = fresh_vault();
        let n0 = create_note(&mut v0, seed.clone()).unwrap();
        let baseline =
            update_note_with_options(&mut v0, &n0.id, 1, patch.clone(), RenameOptions::default())
                .unwrap();
        assert_eq!(baseline.version, 2);

        for caller in CALLERS {
            let (_d, mut v) = fresh_vault();
            let n = create_note(&mut v, seed.clone()).unwrap();
            let updated = notes::update_note_as(
                &mut v,
                &n.id,
                1,
                patch.clone(),
                RenameOptions::default(),
                caller,
            )
            .unwrap();
            assert_eq!(shape(&updated), shape(&baseline), "{caller:?} {patch:?}");
            assert_eq!(updated.id, n.id);
            assert_eq!(shape(&get_note(&v, &n.id).unwrap()), shape(&baseline));

            // A second save bumps again, by exactly one.
            let again = notes::update_note_as(
                &mut v,
                &n.id,
                2,
                UpdateNote {
                    content_md: Some("third".into()),
                    ..Default::default()
                },
                RenameOptions::default(),
                caller,
            )
            .unwrap();
            assert_eq!(again.version, 3, "{caller:?}");
            assert_eq!(again.content_md, "third");
        }
    }
}

/// A target "Old Title" plus a linker that references it four ways, indexed.
fn rename_fixture() -> (tempfile::TempDir, Vault, NoteId, String) {
    let (dir, mut vault) = fresh_vault();
    let target = create_note(
        &mut vault,
        CreateNote {
            title: Some("Old Title".into()),
            content_md: "# Old Title\n".into(),
            ..Default::default()
        },
    )
    .unwrap();
    let linker_body = "See [[Old Title]], [[Old Title~extends]], [[Old Title|aka]] and [[Other]].";
    let linker = create_note(
        &mut vault,
        CreateNote {
            title: Some("Linker".into()),
            content_md: linker_body.into(),
            ..Default::default()
        },
    )
    .unwrap();
    indexer::reindex_note(
        vault.connection_mut(),
        linker.id.as_str(),
        linker_body,
        None,
    )
    .unwrap();
    let linker_id = linker.id.as_str().to_string();
    (dir, vault, target.id, linker_id)
}

fn rename_patch() -> UpdateNote {
    UpdateNote {
        title: Some("New Title".into()),
        ..Default::default()
    }
}

#[test]
fn update_note_as_runs_the_rename_links_pass_for_both_callers() {
    let (_d0, mut v0, t0, l0) = rename_fixture();
    update_note_with_options(&mut v0, &t0, 1, rename_patch(), RenameOptions::default()).unwrap();
    let baseline_linker = body_of(&v0, &l0);
    assert_eq!(
        baseline_linker,
        "See [[New Title]], [[New Title~extends]], [[New Title|aka]] and [[Other]]."
    );

    for caller in CALLERS {
        let (_d, mut v, target, linker) = rename_fixture();
        let renamed = notes::update_note_as(
            &mut v,
            &target,
            1,
            rename_patch(),
            RenameOptions::default(),
            caller,
        )
        .unwrap();
        assert_eq!(renamed.title, "New Title");
        assert_eq!(renamed.version, 2);
        assert_eq!(body_of(&v, &linker), baseline_linker, "{caller:?}");

        // The rewritten linker was reindexed: its links still resolve to the target.
        let incoming = links::links_in_for_note(&v, target.as_str(), None).unwrap();
        assert_eq!(incoming.len(), 3, "{caller:?}: {incoming:?}");
        assert!(
            incoming
                .iter()
                .all(|l| l.from_note_id == linker && l.link_text == "New Title"),
            "{caller:?}: {incoming:?}"
        );
    }
}

#[test]
fn update_note_as_skips_the_rename_links_pass_when_disabled() {
    for caller in CALLERS {
        let (_d, mut v, target, linker) = rename_fixture();
        let before = body_of(&v, &linker);
        let renamed = notes::update_note_as(
            &mut v,
            &target,
            1,
            rename_patch(),
            RenameOptions {
                rename_links: false,
            },
            caller,
        )
        .unwrap();
        assert_eq!(renamed.title, "New Title");
        assert_eq!(renamed.version, 2);
        assert_eq!(body_of(&v, &linker), before, "{caller:?}");
        assert_eq!(version_of(&v, &linker), 1, "{caller:?}");
    }
}

#[test]
fn update_note_as_returns_version_conflict_on_stale_expected_version() {
    for caller in CALLERS {
        let (_d, mut v) = fresh_vault();
        let n = create_note(
            &mut v,
            CreateNote {
                title: Some("Conflicted".into()),
                content_md: "v1".into(),
                ..Default::default()
            },
        )
        .unwrap();
        notes::update_note_as(
            &mut v,
            &n.id,
            1,
            UpdateNote {
                content_md: Some("v2".into()),
                ..Default::default()
            },
            RenameOptions::default(),
            caller,
        )
        .unwrap();

        // Stale (behind) and ahead are both conflicts.
        for stale in [1, 3] {
            let err = notes::update_note_as(
                &mut v,
                &n.id,
                stale,
                UpdateNote {
                    content_md: Some("lost".into()),
                    ..Default::default()
                },
                RenameOptions::default(),
                caller,
            )
            .unwrap_err();
            match err {
                MemexError::VersionConflict { expected, current } => {
                    assert_eq!((expected, current), (stale, 2), "{caller:?}");
                }
                other => panic!("{caller:?}: expected VersionConflict, got {other:?}"),
            }
        }
        let stored = get_note(&v, &n.id).unwrap();
        assert_eq!((stored.content_md.as_str(), stored.version), ("v2", 2));
    }
}

#[test]
fn update_note_as_returns_not_found_for_a_missing_note() {
    for caller in CALLERS {
        let (_d, mut v) = fresh_vault();
        let missing = NoteId::new();
        let err = notes::update_note_as(
            &mut v,
            &missing,
            1,
            UpdateNote {
                content_md: Some("x".into()),
                ..Default::default()
            },
            RenameOptions::default(),
            caller,
        )
        .unwrap_err();
        assert!(
            matches!(err, MemexError::NotFound(_)),
            "{caller:?}: {err:?}"
        );
    }
}

#[test]
fn update_note_as_rejects_a_title_collision_like_update_note_with_options() {
    for caller in CALLERS {
        let (_d, mut v) = fresh_vault();
        let existing = create_note(
            &mut v,
            CreateNote {
                title: Some("Existing".into()),
                content_md: "e".into(),
                ..Default::default()
            },
        )
        .unwrap();
        let n = create_note(
            &mut v,
            CreateNote {
                title: Some("Mine".into()),
                content_md: "m".into(),
                ..Default::default()
            },
        )
        .unwrap();
        let err = notes::update_note_as(
            &mut v,
            &n.id,
            1,
            UpdateNote {
                title: Some("Existing".into()),
                ..Default::default()
            },
            RenameOptions::default(),
            caller,
        )
        .unwrap_err();
        match err {
            MemexError::TitleConflict { existing_id, .. } => {
                assert_eq!(existing_id, existing.id.as_str(), "{caller:?}");
            }
            other => panic!("{caller:?}: expected TitleConflict, got {other:?}"),
        }
        assert_eq!(get_note(&v, &n.id).unwrap().version, 1);
    }
}

// ---------- AC4: update_link_as ----------

/// A "Target" note plus a "Source" note whose body is `content`, indexed.
fn link_fixture(content: &str) -> (tempfile::TempDir, Vault, String) {
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
    indexer::reindex_note(vault.connection_mut(), src.id.as_str(), content, None).unwrap();
    let src_id = src.id.as_str().to_string();
    (dir, vault, src_id)
}

fn first_link_id(vault: &Vault, src: &str) -> String {
    links::links_out_for_note(vault, src).unwrap()[0].id.clone()
}

fn link_patches() -> Vec<UpdateLink> {
    vec![
        UpdateLink {
            new_kind: Some(LinkKind::new("extends").unwrap()),
            new_label: None,
        },
        UpdateLink {
            new_kind: None,
            new_label: Some(Some("alias".into())),
        },
        UpdateLink {
            new_kind: Some(LinkKind::new("contradicts").unwrap()),
            new_label: Some(Some("both".into())),
        },
        UpdateLink {
            new_kind: Some(LinkKind::references()),
            new_label: Some(None),
        },
    ]
}

#[test]
fn update_link_as_changes_kind_and_label_like_update_link() {
    let content = "Intro [[Target~example-of|old]] and [[Other]] tail.";
    for patch in link_patches() {
        let (_d0, mut v0, s0) = link_fixture(content);
        let l0 = first_link_id(&v0, &s0);
        let baseline = links::update_link(&mut v0, &l0, patch.clone()).unwrap();
        let baseline_body = body_of(&v0, &s0);
        assert_ne!(baseline_body, content, "{patch:?} must change the body");

        for caller in CALLERS {
            let (_d, mut v, src) = link_fixture(content);
            let link_id = first_link_id(&v, &src);
            let updated = links::update_link_as(&mut v, &link_id, patch.clone(), caller).unwrap();

            assert_eq!(
                updated.link_kind, baseline.link_kind,
                "{caller:?} {patch:?}"
            );
            assert_eq!(updated.label, baseline.label, "{caller:?} {patch:?}");
            assert_eq!(updated.link_text, "Target");
            assert_eq!(updated.position, baseline.position);
            assert_eq!(updated.source, baseline.source);
            assert_eq!(body_of(&v, &src), baseline_body, "{caller:?} {patch:?}");

            // The source note was saved through the versioned update path once.
            assert_eq!(version_of(&v, &src), 2, "{caller:?}");

            // The links table was reindexed from the saved body.
            let out = links::links_out_for_note(&v, &src).unwrap();
            assert_eq!(out.len(), 2);
            assert_eq!(out[0].link_kind, baseline.link_kind);
            assert_eq!(out[0].label, baseline.label);
            assert!(out[0].to_note_id.is_some(), "still resolves to Target");
        }
    }
}

#[test]
fn update_link_as_with_no_effective_change_does_not_save() {
    let content = "Hello [[Target~extends|x]] world.";
    for caller in CALLERS {
        let (_d, mut v, src) = link_fixture(content);
        let link_id = first_link_id(&v, &src);
        let unchanged = links::update_link_as(
            &mut v,
            &link_id,
            UpdateLink {
                new_kind: Some(LinkKind::new("extends").unwrap()),
                new_label: Some(Some("x".into())),
            },
            caller,
        )
        .unwrap();
        assert_eq!(unchanged.id, link_id);
        assert_eq!(unchanged.link_kind.as_str(), "extends");
        assert_eq!(unchanged.label.as_deref(), Some("x"));
        assert_eq!(version_of(&v, &src), 1, "{caller:?}");
        assert_eq!(body_of(&v, &src), content);
    }
}

#[test]
fn update_link_as_rejects_a_frontmatter_kind_change_like_update_link() {
    let content = "---\nextends:\n  - [[Target]]\n---\n# Source\n";
    for caller in CALLERS {
        let (_d, mut v, src) = link_fixture(content);
        let link_id = first_link_id(&v, &src);
        let err = links::update_link_as(
            &mut v,
            &link_id,
            UpdateLink {
                new_kind: Some(LinkKind::new("contradicts").unwrap()),
                new_label: None,
            },
            caller,
        )
        .unwrap_err();
        assert!(
            matches!(err, MemexError::InvalidLinkKind(_)),
            "{caller:?}: {err:?}"
        );
        assert_eq!(body_of(&v, &src), content);
        assert_eq!(version_of(&v, &src), 1);
    }
}

#[test]
fn update_link_as_returns_not_found_for_an_unknown_link() {
    for caller in CALLERS {
        let (_d, mut v, _src) = link_fixture("Hello [[Target]].");
        let err = links::update_link_as(
            &mut v,
            "01JZZZZZZZZZZZZZZZZZZZZZZZ",
            UpdateLink {
                new_kind: Some(LinkKind::new("extends").unwrap()),
                new_label: None,
            },
            caller,
        )
        .unwrap_err();
        assert!(
            matches!(err, MemexError::NotFound(_)),
            "{caller:?}: {err:?}"
        );
    }
}

// ---------- AC9: feature modules ----------

#[test]
fn feature_modules_are_public() {
    #[allow(unused_imports)]
    use memex_core::{
        blocks, caller, daily, excerpts, footer, review, smart_folders, transclusion,
        vault_settings,
    };
    // `Caller` lives in the `caller` module.
    let c: caller::Caller = Caller::Person;
    assert_eq!(c, Caller::Person);
}
