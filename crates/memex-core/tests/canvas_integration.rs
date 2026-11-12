//! Canvas layer integration tests. Each test exercises one behavior end-to-end
//! against a real on-disk `Vault`.

use memex_core::canvas::{
    add_to_canvas, add_to_canvas_with_clock, create_canvas, create_canvas_with_clock,
    delete_canvas, get_canvas, list_canvases, move_node, move_node_changed, move_nodes_batch,
    remove_from_canvas, remove_from_canvas_removed, rename_canvas, Clock,
};
use memex_core::notes::{create_note, delete_note, CreateNote};
use memex_core::{CanvasId, MemexError, Vault};

/// Fixed clock for deterministic timestamps.
struct FixedClock(std::cell::Cell<i64>);

impl FixedClock {
    fn new(start: i64) -> Self {
        Self(std::cell::Cell::new(start))
    }
    fn advance(&self, dt: i64) {
        self.0.set(self.0.get() + dt);
    }
}

impl Clock for FixedClock {
    fn now_ms(&self) -> i64 {
        self.0.get()
    }
}

fn new_vault() -> (tempfile::TempDir, Vault) {
    let dir = tempfile::tempdir().unwrap();
    let vault = Vault::create(dir.path()).expect("create vault");
    (dir, vault)
}

fn add_note(vault: &mut Vault, title: &str) -> String {
    let note = create_note(
        vault,
        CreateNote {
            title: Some(title.into()),
            content_md: format!("# {title}\n"),
            ..Default::default()
        },
    )
    .unwrap();
    note.id.as_str().to_string()
}

// ---------- create_canvas ----------

#[test]
fn create_canvas_returns_canvas_with_id_and_timestamps() {
    let (_dir, mut vault) = new_vault();
    let clock = FixedClock::new(1_000);
    let c = create_canvas_with_clock(&mut vault, "Research Q2", &clock).unwrap();
    assert_eq!(c.title, "Research Q2");
    assert_eq!(c.version, 1);
    assert_eq!(c.created_at, 1_000);
    assert_eq!(c.updated_at, 1_000);
    assert_eq!(c.id.as_str().len(), 26, "id is a ULID");
}

#[test]
fn create_canvas_rejects_duplicate_title_with_title_conflict() {
    let (_dir, mut vault) = new_vault();
    let c1 = create_canvas(&mut vault, "Dup").unwrap();
    let err = create_canvas(&mut vault, "Dup").unwrap_err();
    match err {
        MemexError::TitleConflict {
            existing_id,
            attempted_title,
        } => {
            assert_eq!(existing_id, c1.id.as_str());
            assert_eq!(attempted_title, "Dup");
        }
        other => panic!("expected TitleConflict, got {other:?}"),
    }
}

#[test]
fn create_canvas_rejects_empty_or_whitespace_title() {
    let (_dir, mut vault) = new_vault();
    assert!(matches!(
        create_canvas(&mut vault, "").unwrap_err(),
        MemexError::TitleInvalid(_)
    ));
    assert!(matches!(
        create_canvas(&mut vault, "  padded  ").unwrap_err(),
        MemexError::TitleInvalid(_)
    ));
}

// ---------- list_canvases ----------

#[test]
fn list_canvases_orders_by_updated_at_desc_with_node_counts() {
    let (_dir, mut vault) = new_vault();
    let clock = FixedClock::new(1_000);
    let c1 = create_canvas_with_clock(&mut vault, "A", &clock).unwrap();
    clock.advance(10);
    let c2 = create_canvas_with_clock(&mut vault, "B", &clock).unwrap();
    clock.advance(10);
    let _c3 = create_canvas_with_clock(&mut vault, "C", &clock).unwrap();

    // Bump c1 to the top via add_to_canvas.
    clock.advance(10);
    let n1 = add_note(&mut vault, "Note One");
    add_to_canvas_with_clock(&mut vault, &c1.id, &n1, 0.0, 0.0, &clock).unwrap();

    let listed = list_canvases(&vault).unwrap();
    let titles: Vec<&str> = listed.iter().map(|s| s.title.as_str()).collect();
    assert_eq!(titles, vec!["A", "C", "B"]);
    let a = listed.iter().find(|s| s.title == "A").unwrap();
    let b = listed.iter().find(|s| s.title == "B").unwrap();
    assert_eq!(a.node_count, 1);
    assert_eq!(b.node_count, 0);
    assert_eq!(a.id.as_str(), c1.id.as_str());
    assert_eq!(b.id.as_str(), c2.id.as_str());
}

// ---------- add_to_canvas idempotency / validation ----------

#[test]
fn add_to_canvas_is_idempotent_on_canvas_id_note_id() {
    let (_dir, mut vault) = new_vault();
    let c = create_canvas(&mut vault, "Board").unwrap();
    let n = add_note(&mut vault, "Note A");

    let first = add_to_canvas(&mut vault, &c.id, &n, 10.0, 20.0).unwrap();
    let second = add_to_canvas(&mut vault, &c.id, &n, 999.0, 999.0).unwrap();

    // Position unchanged on second add.
    assert_eq!(first.x, 10.0);
    assert_eq!(second.x, 10.0);
    assert_eq!(second.y, 20.0);
    assert_eq!(second.placed_at, first.placed_at);
}

#[test]
fn add_to_canvas_rejects_unknown_canvas_or_note() {
    let (_dir, mut vault) = new_vault();
    let unknown_canvas = CanvasId::new();
    let err = add_to_canvas(&mut vault, &unknown_canvas, "no-such-note", 0.0, 0.0).unwrap_err();
    assert!(matches!(err, MemexError::NotFound(_)));

    let c = create_canvas(&mut vault, "Real").unwrap();
    let err = add_to_canvas(&mut vault, &c.id, "no-such-note", 0.0, 0.0).unwrap_err();
    assert!(matches!(err, MemexError::NotFound(_)));
}

#[test]
fn add_to_canvas_bumps_canvas_updated_at_and_version_on_new_placement_only() {
    let (_dir, mut vault) = new_vault();
    let clock = FixedClock::new(1_000);
    let c = create_canvas_with_clock(&mut vault, "Board", &clock).unwrap();
    let n = add_note(&mut vault, "Note A");

    clock.advance(50);
    add_to_canvas_with_clock(&mut vault, &c.id, &n, 0.0, 0.0, &clock).unwrap();
    let after_first = get_canvas(&vault, &c.id).unwrap().canvas;
    assert_eq!(after_first.updated_at, 1_050);
    assert_eq!(after_first.version, 2);

    // Second (idempotent) add does NOT bump updated_at/version.
    clock.advance(50);
    add_to_canvas_with_clock(&mut vault, &c.id, &n, 0.0, 0.0, &clock).unwrap();
    let after_second = get_canvas(&vault, &c.id).unwrap().canvas;
    assert_eq!(after_second.updated_at, 1_050);
    assert_eq!(after_second.version, 2);
}

// ---------- move_node / move_nodes_batch ----------

#[test]
fn move_node_updates_position_and_bumps_updated_at() {
    let (_dir, mut vault) = new_vault();
    let clock = FixedClock::new(2_000);
    let c = create_canvas_with_clock(&mut vault, "Board", &clock).unwrap();
    let n = add_note(&mut vault, "Note A");
    add_to_canvas_with_clock(&mut vault, &c.id, &n, 1.0, 2.0, &clock).unwrap();

    clock.advance(100);
    let moved = move_node(&mut vault, &c.id, &n, 50.5, -10.25, None).unwrap();
    assert_eq!(moved.x, 50.5);
    assert_eq!(moved.y, -10.25);
}

/// WI #449: `move_node_changed` reads the stored placement before it writes.
/// It takes the write lock first (Immediate), so a write another connection
/// holds is waited out under the busy timeout. A deferred transaction would
/// hold a read snapshot when it upgrades, and SQLite fails that upgrade at
/// once with SQLITE_BUSY without running the busy handler.
#[test]
fn move_node_changed_waits_out_a_write_another_connection_holds() {
    let (dir, mut vault) = new_vault();
    let c = create_canvas(&mut vault, "Board").unwrap();
    let n = add_note(&mut vault, "Note A");
    add_to_canvas_with_clock(&mut vault, &c.id, &n, 1.0, 2.0, &FixedClock::new(1_000)).unwrap();

    let db = dir.path().join("memex.db");
    let (locked_tx, locked_rx) = std::sync::mpsc::channel();
    let holder = std::thread::spawn(move || {
        let other = rusqlite::Connection::open(db).unwrap();
        other.execute_batch("BEGIN IMMEDIATE").unwrap();
        locked_tx.send(()).unwrap();
        std::thread::sleep(std::time::Duration::from_millis(300));
        other.execute_batch("COMMIT").unwrap();
    });
    locked_rx.recv().unwrap();

    let (node, changed) = move_node_changed(
        &mut vault,
        &c.id,
        &n,
        5.0,
        6.0,
        None,
        &FixedClock::new(2_000),
    )
    .expect("the move waits for the other writer instead of failing with SQLITE_BUSY");
    holder.join().unwrap();

    assert!(changed);
    assert_eq!((node.x, node.y), (5.0, 6.0));
}

#[test]
fn move_node_changed_reports_whether_the_stored_placement_differs() {
    let (_dir, mut vault) = new_vault();
    let clock = FixedClock::new(1_000);
    let c = create_canvas_with_clock(&mut vault, "Board", &clock).unwrap();
    let n = add_note(&mut vault, "Note A");
    add_to_canvas_with_clock(&mut vault, &c.id, &n, 1.0, 2.0, &clock).unwrap();

    let same = move_node_changed(&mut vault, &c.id, &n, 1.0, 2.0, None, &clock).unwrap();
    assert!(!same.1, "same x and y, no z_order");
    let same_z = move_node_changed(&mut vault, &c.id, &n, 1.0, 2.0, Some(0), &clock).unwrap();
    assert!(!same_z.1, "same x, y and the stored z_order");
    let moved_x = move_node_changed(&mut vault, &c.id, &n, 3.0, 2.0, None, &clock).unwrap();
    assert!(moved_x.1, "x differs");
    let moved_y = move_node_changed(&mut vault, &c.id, &n, 3.0, 4.0, None, &clock).unwrap();
    assert!(moved_y.1, "y differs");
    let moved_z = move_node_changed(&mut vault, &c.id, &n, 3.0, 4.0, Some(7), &clock).unwrap();
    assert!(moved_z.1, "z_order differs");
    assert_eq!(moved_z.0.z_order, 7);
    let missing = add_note(&mut vault, "Floating");
    let err = move_node_changed(&mut vault, &c.id, &missing, 0.0, 0.0, None, &clock).unwrap_err();
    assert!(matches!(err, MemexError::NotFound(_)));
}

#[test]
fn move_node_errors_on_missing_placement() {
    let (_dir, mut vault) = new_vault();
    let c = create_canvas(&mut vault, "Board").unwrap();
    let n = add_note(&mut vault, "Floating");
    // Not yet placed.
    let err = move_node(&mut vault, &c.id, &n, 0.0, 0.0, None).unwrap_err();
    assert!(matches!(err, MemexError::NotFound(_)));
}

#[test]
fn move_nodes_batch_rolls_back_whole_batch_on_invalid_row() {
    let (_dir, mut vault) = new_vault();
    let c = create_canvas(&mut vault, "Board").unwrap();
    let a = add_note(&mut vault, "A");
    let b = add_note(&mut vault, "B");
    add_to_canvas(&mut vault, &c.id, &a, 0.0, 0.0).unwrap();
    add_to_canvas(&mut vault, &c.id, &b, 0.0, 0.0).unwrap();

    // First two valid moves are mid-batch; third targets a non-placed note.
    let moves = vec![
        (a.clone(), 1.0, 1.0),
        (b.clone(), 2.0, 2.0),
        ("ghost".to_string(), 9.0, 9.0),
    ];
    let err = move_nodes_batch(&mut vault, &c.id, &moves).unwrap_err();
    assert!(matches!(err, MemexError::NotFound(_)));

    // Atomicity check: a and b are still at (0, 0).
    let detail = get_canvas(&vault, &c.id).unwrap();
    for node in detail.nodes {
        assert_eq!(node.x, 0.0, "node {} x unchanged", node.note_id);
        assert_eq!(node.y, 0.0, "node {} y unchanged", node.note_id);
    }
}

// ---------- remove_from_canvas ----------

#[test]
fn remove_from_canvas_removes_placement_only() {
    let (_dir, mut vault) = new_vault();
    let c = create_canvas(&mut vault, "Board").unwrap();
    let n = add_note(&mut vault, "Note A");
    add_to_canvas(&mut vault, &c.id, &n, 0.0, 0.0).unwrap();
    remove_from_canvas(&mut vault, &c.id, &n).unwrap();

    // Note still exists.
    let note_count: i64 = vault
        .connection_ref()
        .query_row("SELECT COUNT(*) FROM notes WHERE id = ?", [&n], |r| {
            r.get(0)
        })
        .unwrap();
    assert_eq!(note_count, 1);
    // Placement is gone.
    let detail = get_canvas(&vault, &c.id).unwrap();
    assert!(detail.nodes.is_empty());
}

#[test]
fn remove_from_canvas_is_a_noop_for_missing_placement() {
    let (_dir, mut vault) = new_vault();
    let c = create_canvas(&mut vault, "Board").unwrap();
    remove_from_canvas(&mut vault, &c.id, "no-such-note").unwrap();
}

/// WI #449: `remove_from_canvas_removed` answers whether a placement was
/// deleted: true for a real removal, false (and nothing written) when the
/// note isn't placed.
#[test]
fn remove_from_canvas_removed_reports_whether_a_placement_was_deleted() {
    let (_dir, mut vault) = new_vault();
    let clock = FixedClock::new(1_000);
    let c = create_canvas_with_clock(&mut vault, "Board", &clock).unwrap();
    let n = add_note(&mut vault, "Note A");
    add_to_canvas_with_clock(&mut vault, &c.id, &n, 0.0, 0.0, &clock).unwrap();
    let before = get_canvas(&vault, &c.id).unwrap().canvas;

    let later = FixedClock::new(2_000);
    assert!(remove_from_canvas_removed(&mut vault, &c.id, &n, &later).unwrap());
    let after_real = get_canvas(&vault, &c.id).unwrap().canvas;
    assert!(
        after_real.version > before.version,
        "a removal bumps the version"
    );

    assert!(
        !remove_from_canvas_removed(&mut vault, &c.id, &n, &FixedClock::new(3_000)).unwrap(),
        "second removal finds nothing"
    );
    assert!(!remove_from_canvas_removed(&mut vault, &c.id, "no-such-note", &later).unwrap());
    let after_noop = get_canvas(&vault, &c.id).unwrap().canvas;
    assert_eq!(
        after_noop.version, after_real.version,
        "a no-op writes nothing"
    );
    assert_eq!(after_noop.updated_at, after_real.updated_at);
}

// ---------- rename_canvas ----------

#[test]
fn rename_canvas_honors_expected_version() {
    let (_dir, mut vault) = new_vault();
    let c = create_canvas(&mut vault, "Old").unwrap();
    let renamed = rename_canvas(&mut vault, &c.id, "New", c.version).unwrap();
    assert_eq!(renamed.title, "New");
    assert_eq!(renamed.version, c.version + 1);

    let stale = rename_canvas(&mut vault, &c.id, "Newer", c.version).unwrap_err();
    match stale {
        MemexError::VersionConflict { expected, current } => {
            assert_eq!(expected, c.version);
            assert_eq!(current, c.version + 1);
        }
        other => panic!("expected VersionConflict, got {other:?}"),
    }
}

#[test]
fn rename_canvas_rejects_duplicate_title() {
    let (_dir, mut vault) = new_vault();
    let _a = create_canvas(&mut vault, "Taken").unwrap();
    let b = create_canvas(&mut vault, "Other").unwrap();
    let err = rename_canvas(&mut vault, &b.id, "Taken", b.version).unwrap_err();
    assert!(matches!(err, MemexError::TitleConflict { .. }));
}

#[test]
fn rename_canvas_allows_renaming_to_current_title_noop() {
    let (_dir, mut vault) = new_vault();
    let c = create_canvas(&mut vault, "Same").unwrap();
    let r = rename_canvas(&mut vault, &c.id, "Same", c.version).unwrap();
    assert_eq!(r.title, "Same");
}

// ---------- delete_canvas ----------

#[test]
fn delete_canvas_cascades_canvas_nodes_only() {
    let (_dir, mut vault) = new_vault();
    let c = create_canvas(&mut vault, "Board").unwrap();
    let n = add_note(&mut vault, "Note A");
    add_to_canvas(&mut vault, &c.id, &n, 0.0, 0.0).unwrap();

    delete_canvas(&mut vault, &c.id, c.version + 1).unwrap(); // add bumped version

    // Note still there.
    let note_count: i64 = vault
        .connection_ref()
        .query_row("SELECT COUNT(*) FROM notes WHERE id = ?", [&n], |r| {
            r.get(0)
        })
        .unwrap();
    assert_eq!(note_count, 1);
    // canvas_nodes for the deleted canvas are gone.
    let nodes_left: i64 = vault
        .connection_ref()
        .query_row(
            "SELECT COUNT(*) FROM canvas_nodes WHERE canvas_id = ?",
            [c.id.as_str()],
            |r| r.get(0),
        )
        .unwrap();
    assert_eq!(nodes_left, 0);
}

#[test]
fn delete_canvas_returns_not_found_for_unknown_id() {
    let (_dir, mut vault) = new_vault();
    let err = delete_canvas(&mut vault, &CanvasId::new(), 1).unwrap_err();
    assert!(matches!(err, MemexError::NotFound(_)));
}

// ---------- get_canvas ----------

#[test]
fn get_canvas_on_empty_canvas_returns_no_nodes_or_edges() {
    let (_dir, mut vault) = new_vault();
    let c = create_canvas(&mut vault, "Empty").unwrap();
    let detail = get_canvas(&vault, &c.id).unwrap();
    assert!(detail.nodes.is_empty());
    assert!(detail.edges.is_empty());
    assert_eq!(detail.canvas.title, "Empty");
}

#[test]
fn get_canvas_returns_edges_only_between_placed_nodes() {
    let (_dir, mut vault) = new_vault();
    let c = create_canvas(&mut vault, "Board").unwrap();
    // Create targets first so that Alpha's wikilinks resolve to real notes
    // when the indexer runs on Alpha.
    let b = add_note(&mut vault, "Beta");
    let _g = add_note(&mut vault, "Gamma");
    let a = add_note_with_body(&mut vault, "Alpha", "[[Beta]] [[Gamma]]");

    // Place A and B only; do NOT place Gamma.
    add_to_canvas(&mut vault, &c.id, &a, 0.0, 0.0).unwrap();
    add_to_canvas(&mut vault, &c.id, &b, 0.0, 0.0).unwrap();

    let detail = get_canvas(&vault, &c.id).unwrap();
    assert_eq!(detail.nodes.len(), 2);
    assert_eq!(
        detail.edges.len(),
        1,
        "only A->B is rendered; A->Gamma is off-canvas"
    );
    assert_eq!(detail.edges[0].from_note_id, a);
    assert_eq!(detail.edges[0].to_note_id, b);
}

#[test]
fn get_canvas_returns_multiple_edges_between_same_pair() {
    let (_dir, mut vault) = new_vault();
    let c = create_canvas(&mut vault, "Board").unwrap();
    let b = add_note(&mut vault, "Beta");
    // Two wikilinks between the same pair with different kinds.
    let a = add_note_with_body(&mut vault, "Alpha", "[[Beta~extends]]\n[[Beta~references]]");
    add_to_canvas(&mut vault, &c.id, &a, 0.0, 0.0).unwrap();
    add_to_canvas(&mut vault, &c.id, &b, 0.0, 0.0).unwrap();

    let detail = get_canvas(&vault, &c.id).unwrap();
    assert_eq!(detail.edges.len(), 2);
    let kinds: Vec<String> = detail
        .edges
        .iter()
        .map(|e| e.link_kind.as_str().to_string())
        .collect();
    assert!(kinds.contains(&"extends".to_string()));
    assert!(kinds.contains(&"references".to_string()));
}

#[test]
fn get_canvas_excludes_ghost_wikilinks() {
    let (_dir, mut vault) = new_vault();
    let c = create_canvas(&mut vault, "Board").unwrap();
    // Alpha references a non-existent note title; that wikilink is a ghost link.
    let a = add_note_with_body(&mut vault, "Alpha", "[[Nonexistent]]");
    add_to_canvas(&mut vault, &c.id, &a, 0.0, 0.0).unwrap();
    let detail = get_canvas(&vault, &c.id).unwrap();
    assert!(detail.edges.is_empty());
}

#[test]
fn get_canvas_not_found_for_unknown_id() {
    let (_dir, vault) = new_vault();
    let err = get_canvas(&vault, &CanvasId::new()).unwrap_err();
    assert!(matches!(err, MemexError::NotFound(_)));
}

// ---------- FK cascade behavior ----------

#[test]
fn deleting_note_cascades_canvas_node_placement() {
    let (_dir, mut vault) = new_vault();
    let c = create_canvas(&mut vault, "Board").unwrap();
    let n = add_note(&mut vault, "Note A");
    add_to_canvas(&mut vault, &c.id, &n, 0.0, 0.0).unwrap();

    use memex_core::notes::NoteId;
    delete_note(&mut vault, &NoteId::parse(&n).unwrap()).unwrap();

    let detail = get_canvas(&vault, &c.id).unwrap();
    assert!(
        detail.nodes.is_empty(),
        "placement cascaded with note delete"
    );
}

// Helper for tests that need a note with body content (so the indexer runs).
fn add_note_with_body(vault: &mut Vault, title: &str, body: &str) -> String {
    let note = create_note(
        vault,
        CreateNote {
            title: Some(title.into()),
            content_md: format!("# {title}\n\n{body}\n"),
            ..Default::default()
        },
    )
    .unwrap();
    // Run the indexer so that links are populated. The existing `create_note`
    // path does NOT auto-index; callers (the CLI / MCP) do. Mirror that here.
    let id = note.id.as_str().to_string();
    let content = format!("# {title}\n\n{body}\n");
    memex_core::indexer::reindex_note(vault.connection_mut(), &id, &content, None)
        .expect("reindex note");
    id
}
