//! WI #13 (R10): Smart Folders, pinning and the depth limit in core.
//!
//! Real SQLite, real V5 schema. Every operation takes a `Caller`; pinning
//! rules guard `Caller::Agent` only, person writes pin what they touch, and
//! the depth limit (`vault_settings.smart_folder_max_depth`, default 2) binds
//! every caller. Root is depth 1; `required_depth` = new parent's depth (0 for
//! root) + height of the created or moved subtree (a leaf has height 1).

use std::cell::Cell;
use std::collections::BTreeSet;

use memex_core::notes::{self, CreateNote, NoteId};
use memex_core::smart_folders::{
    self as sf, FolderUpdate, ListedFolder, NewParent, SmartFolder, SmartFolderList,
};
use memex_core::vault_settings;
use memex_core::{Caller, Clock, MemexError, Vault};
use serde_json::{json, Value};

const CALLERS: [Caller; 2] = [Caller::Person, Caller::Agent];
const T0: i64 = 1_759_500_000_000;

struct FakeClock(Cell<i64>);

impl FakeClock {
    fn at(ms: i64) -> Self {
        Self(Cell::new(ms))
    }
    fn set(&self, ms: i64) {
        self.0.set(ms);
    }
}

impl Clock for FakeClock {
    fn now_ms(&self) -> i64 {
        self.0.get()
    }
}

fn fresh() -> (tempfile::TempDir, Vault) {
    let dir = tempfile::tempdir().unwrap();
    let vault = Vault::create(dir.path().join("vault")).unwrap();
    (dir, vault)
}

fn clock() -> FakeClock {
    FakeClock::at(T0)
}

// ---------- fixtures ----------

fn mk(v: &mut Vault, name: &str, parent: Option<&str>, caller: Caller) -> SmartFolder {
    sf::create_folder(v, name, parent, caller, &clock())
        .unwrap_or_else(|e| panic!("create_folder({name}) failed: {e}"))
}

fn person(v: &mut Vault, name: &str, parent: Option<&str>) -> String {
    mk(v, name, parent, Caller::Person).id
}

fn agent(v: &mut Vault, name: &str, parent: Option<&str>) -> String {
    mk(v, name, parent, Caller::Agent).id
}

fn set_max(v: &mut Vault, n: i64) {
    let got = vault_settings::set_setting(v, "smart_folder_max_depth", &n.to_string())
        .unwrap_or_else(|e| panic!("set max depth {n}: {e}"));
    assert_eq!(got, n);
}

fn note_with(v: &mut Vault, title: &str, content: &str, fm: Value) -> String {
    notes::create_note(
        v,
        CreateNote {
            title: Some(title.into()),
            content_md: content.into(),
            frontmatter: Some(fm),
        },
    )
    .unwrap()
    .id
    .to_string()
}

fn topic(v: &mut Vault, title: &str) -> String {
    note_with(
        v,
        title,
        &format!("{title} notes."),
        json!({"role": "topic"}),
    )
}

fn roleless(v: &mut Vault, title: &str) -> String {
    note_with(v, title, &format!("{title} body."), json!({}))
}

fn daily(v: &mut Vault, date: &str) -> String {
    note_with(v, date, "", json!({"role": "daily"}))
}

fn add(v: &mut Vault, folder: &str, note: &str, caller: Caller) -> sf::Membership {
    sf::add_member(v, folder, note, None, caller, None)
        .unwrap_or_else(|e| panic!("add_member({folder}, {note}) failed: {e}"))
}

/// `update_folder` at the base time; returns the raw result so tests can
/// assert errors.
fn update(
    v: &mut Vault,
    id: &str,
    u: FolderUpdate,
    caller: Caller,
) -> memex_core::Result<SmartFolder> {
    sf_update(v, id, u, caller, &clock())
}

fn sf_update(
    v: &mut Vault,
    id: &str,
    u: FolderUpdate,
    caller: Caller,
    clock: &dyn Clock,
) -> memex_core::Result<SmartFolder> {
    sf::update_folder(v, id, u, caller, clock)
}

fn rename(name: &str) -> FolderUpdate {
    FolderUpdate {
        name: Some(name.into()),
        ..Default::default()
    }
}

fn move_under(parent: &str) -> FolderUpdate {
    FolderUpdate {
        parent: Some(NewParent::Folder(parent.into())),
        ..Default::default()
    }
}

fn to_root() -> FolderUpdate {
    FolderUpdate {
        parent: Some(NewParent::Root),
        ..Default::default()
    }
}

fn pin(p: bool) -> FolderUpdate {
    FolderUpdate {
        pinned: Some(p),
        ..Default::default()
    }
}

// ---------- reads ----------

fn list(v: &Vault) -> SmartFolderList {
    sf::list_folders(v).unwrap()
}

fn listed(v: &Vault, id: &str) -> ListedFolder {
    list(v)
        .folders
        .into_iter()
        .find(|f| f.folder.id == id)
        .unwrap_or_else(|| panic!("folder {id} not listed"))
}

fn folder(v: &Vault, id: &str) -> SmartFolder {
    listed(v, id).folder
}

fn folder_ids(v: &Vault) -> BTreeSet<String> {
    list(v).folders.into_iter().map(|f| f.folder.id).collect()
}

fn member_pin(v: &Vault, folder_id: &str, note_id: &str) -> Option<bool> {
    listed(v, folder_id)
        .members
        .into_iter()
        .find(|m| m.note_id == note_id)
        .map(|m| m.pinned)
}

fn member_ids(v: &Vault, folder_id: &str) -> BTreeSet<String> {
    listed(v, folder_id)
        .members
        .into_iter()
        .map(|m| m.note_id)
        .collect()
}

fn unsorted_ids(v: &Vault) -> BTreeSet<String> {
    list(v).unsorted.into_iter().map(|u| u.note_id).collect()
}

fn membership_rows(v: &Vault, folder_id: &str, note_id: &str) -> i64 {
    v.connection_ref()
        .query_row(
            "SELECT COUNT(*) FROM smart_folder_members WHERE smart_folder_id = ? AND note_id = ?",
            [folder_id, note_id],
            |r| r.get(0),
        )
        .unwrap()
}

fn frontmatter(v: &Vault, id: &str) -> Value {
    notes::get_note(v, &NoteId::parse(id).unwrap())
        .unwrap()
        .frontmatter
}

fn version(v: &Vault, id: &str) -> i64 {
    notes::get_note(v, &NoteId::parse(id).unwrap())
        .unwrap()
        .version
}

fn note_count(v: &Vault) -> i64 {
    v.connection_ref()
        .query_row("SELECT COUNT(*) FROM notes", [], |r| r.get(0))
        .unwrap()
}

/// Every row this WI may touch, for "nothing changes" assertions.
#[derive(Debug, PartialEq)]
struct Snapshot {
    folders: Vec<(String, String, Option<String>, i64, i64, i64)>,
    members: Vec<(String, String, i64)>,
    notes: Vec<(String, String, String, i64)>,
    settings: Vec<(String, String)>,
}

fn snapshot(v: &Vault) -> Snapshot {
    let c = v.connection_ref();
    let folders = c
        .prepare(
            "SELECT id, name, parent_id, pinned, created_at, updated_at
             FROM smart_folders ORDER BY id",
        )
        .unwrap()
        .query_map([], |r| {
            Ok((
                r.get(0)?,
                r.get(1)?,
                r.get(2)?,
                r.get(3)?,
                r.get(4)?,
                r.get(5)?,
            ))
        })
        .unwrap()
        .collect::<Result<_, _>>()
        .unwrap();
    let members = c
        .prepare(
            "SELECT smart_folder_id, note_id, pinned FROM smart_folder_members
             ORDER BY smart_folder_id, note_id",
        )
        .unwrap()
        .query_map([], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)))
        .unwrap()
        .collect::<Result<_, _>>()
        .unwrap();
    let notes = c
        .prepare("SELECT id, title, frontmatter, version FROM notes ORDER BY id")
        .unwrap()
        .query_map([], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?)))
        .unwrap()
        .collect::<Result<_, _>>()
        .unwrap();
    let settings = c
        .prepare("SELECT key, value FROM vault_settings ORDER BY key")
        .unwrap()
        .query_map([], |r| Ok((r.get(0)?, r.get(1)?)))
        .unwrap()
        .collect::<Result<_, _>>()
        .unwrap();
    Snapshot {
        folders,
        members,
        notes,
        settings,
    }
}

// ---------- error assertions ----------

fn err<T: std::fmt::Debug>(r: memex_core::Result<T>, what: &str) -> MemexError {
    match r {
        Ok(v) => panic!("{what}: expected an error, got Ok({v:?})"),
        Err(e) => e,
    }
}

fn assert_code(e: &MemexError, code: &str, what: &str) {
    assert_eq!(e.code(), code, "{what}: got {e:?}");
}

fn assert_depth(e: &MemexError, max: i64, required: i64, what: &str) {
    match e {
        MemexError::DepthExceeded {
            max_depth,
            required_depth,
        } => {
            assert_eq!(
                (*max_depth, *required_depth),
                (max, required),
                "{what}: max_depth/required_depth"
            );
        }
        other => panic!("{what}: expected DepthExceeded, got {other:?}"),
    }
}

fn assert_pinned(e: &MemexError, expected_item: &str, name_in_message: &str, what: &str) {
    match e {
        MemexError::PinnedRule { item, .. } => {
            assert_eq!(item, expected_item, "{what}: PinnedRule item");
            assert!(
                e.to_string().contains(name_in_message),
                "{what}: message {:?} names {name_in_message:?}",
                e.to_string()
            );
        }
        other => panic!("{what}: expected PinnedRule, got {other:?}"),
    }
}

fn is_ulid(s: &str) -> bool {
    s.len() == 26 && ulid::Ulid::from_string(s).is_ok()
}

// ======================================================================
// AC 1: person-created folders are pinned, agent-created are not; root
// depth 1, child depth 2.
// ======================================================================

#[test]
fn person_created_folder_is_pinned_and_agent_created_is_not() {
    let (_d, mut v) = fresh();
    let p = mk(&mut v, "Games", None, Caller::Person);
    let a = mk(&mut v, "Work", None, Caller::Agent);
    assert!(p.pinned, "person folder pinned on create");
    assert!(!a.pinned, "agent folder unpinned on create");
    assert!(folder(&v, &p.id).pinned);
    assert!(!folder(&v, &a.id).pinned);

    let pc = mk(&mut v, "Platformers", Some(&a.id), Caller::Person);
    let ac = mk(&mut v, "Puzzles", Some(&p.id), Caller::Agent);
    assert!(pc.pinned, "person child pinned even under an agent folder");
    assert!(
        !ac.pinned,
        "agent child unpinned even under a pinned folder"
    );
}

#[test]
fn root_folder_has_depth_one_and_its_child_depth_two() {
    let (_d, mut v) = fresh();
    let c = FakeClock::at(T0 + 7);
    let root = sf::create_folder(&mut v, "Games", None, Caller::Person, &c).unwrap();
    assert!(is_ulid(&root.id), "folder id is a ULID: {}", root.id);
    assert_eq!(root.name, "Games");
    assert_eq!(root.parent_id, None);
    assert_eq!(root.depth, 1);
    assert_eq!(
        root.created_at,
        T0 + 7,
        "created_at from the injected clock"
    );
    assert_eq!(
        root.updated_at,
        T0 + 7,
        "updated_at from the injected clock"
    );

    let child =
        sf::create_folder(&mut v, "Platformers", Some(&root.id), Caller::Agent, &c).unwrap();
    assert_eq!(child.parent_id.as_deref(), Some(root.id.as_str()));
    assert_eq!(child.depth, 2);
    assert_ne!(child.id, root.id);

    // The listing agrees with the returned objects.
    assert_eq!(folder(&v, &root.id), root);
    assert_eq!(folder(&v, &child.id), child);
}

#[test]
fn listed_depth_follows_the_whole_ancestor_chain() {
    let (_d, mut v) = fresh();
    set_max(&mut v, 5);
    let mut parent: Option<String> = None;
    let mut ids = Vec::new();
    for (i, name) in ["L1", "L2", "L3", "L4", "L5"].iter().enumerate() {
        let f = mk(&mut v, name, parent.as_deref(), Caller::Person);
        assert_eq!(f.depth, i as i64 + 1, "{name} returned depth");
        parent = Some(f.id.clone());
        ids.push(f.id);
    }
    for (i, id) in ids.iter().enumerate() {
        assert_eq!(
            folder(&v, id).depth,
            i as i64 + 1,
            "listed depth of L{}",
            i + 1
        );
    }
}

#[test]
fn create_under_a_missing_parent_is_not_found_and_writes_nothing() {
    let (_d, mut v) = fresh();
    let before = snapshot(&v);
    for caller in CALLERS {
        let e = err(
            sf::create_folder(
                &mut v,
                "Orphan",
                Some(&ulid::Ulid::new().to_string()),
                caller,
                &clock(),
            ),
            "create under missing parent",
        );
        assert_code(&e, "not_found", "create under missing parent");
    }
    assert_eq!(snapshot(&v), before);
}

// ======================================================================
// AC 2: sibling names are unique case-insensitively (incl. non-ASCII);
// the same name under a different parent is fine.
// ======================================================================

#[test]
fn sibling_names_clash_case_insensitively_including_non_ascii() {
    let (_d, mut v) = fresh();
    person(&mut v, "Café", None);
    let games = person(&mut v, "Games", None);
    person(&mut v, "Ölfass", Some(&games));
    let before = snapshot(&v);

    for caller in CALLERS {
        for (name, parent) in [
            ("CAFÉ", None),
            ("café", None),
            ("Café", None),
            ("games", None),
            ("GAMES", None),
            ("ÖLFASS", Some(games.as_str())),
            ("ölfass", Some(games.as_str())),
        ] {
            let e = err(
                sf::create_folder(&mut v, name, parent, caller, &clock()),
                &format!("{caller:?} create {name}"),
            );
            assert_code(&e, "name_conflict", &format!("{caller:?} create {name}"));
        }
    }
    assert_eq!(snapshot(&v), before, "a name conflict writes nothing");
}

#[test]
fn same_name_under_a_different_parent_is_allowed() {
    let (_d, mut v) = fresh();
    let games = person(&mut v, "Games", None);
    let work = person(&mut v, "Work", None);
    let a = mk(&mut v, "games", Some(&work), Caller::Person);
    let b = mk(&mut v, "Café", Some(&games), Caller::Agent);
    let c = mk(&mut v, "CAFÉ", Some(&work), Caller::Agent);
    let d = mk(&mut v, "Café", None, Caller::Agent);
    assert_eq!(a.parent_id.as_deref(), Some(work.as_str()));
    assert_eq!(b.parent_id.as_deref(), Some(games.as_str()));
    assert_eq!(c.parent_id.as_deref(), Some(work.as_str()));
    assert_eq!(d.parent_id, None);
    assert_eq!(folder_ids(&v).len(), 6);
}

#[test]
fn rename_to_a_sibling_name_in_another_case_is_name_conflict() {
    let (_d, mut v) = fresh();
    person(&mut v, "Café", None);
    let p = person(&mut v, "Work", None);
    let a = agent(&mut v, "Inbox", None);
    let before = snapshot(&v);
    let e = err(
        update(&mut v, &p, rename("CAFÉ"), Caller::Person),
        "person rename",
    );
    assert_code(&e, "name_conflict", "person rename to CAFÉ");
    let e = err(
        update(&mut v, &a, rename("café"), Caller::Agent),
        "agent rename",
    );
    assert_code(&e, "name_conflict", "agent rename to café");
    assert_eq!(snapshot(&v), before);
}

#[test]
fn renaming_a_folder_to_its_own_name_in_another_case_succeeds() {
    let (_d, mut v) = fresh();
    let p = person(&mut v, "Café", None);
    let a = agent(&mut v, "games", None);
    let got = update(&mut v, &p, rename("CAFÉ"), Caller::Person).unwrap();
    assert_eq!(got.name, "CAFÉ");
    let got = update(&mut v, &a, rename("Games"), Caller::Agent).unwrap();
    assert_eq!(got.name, "Games");
    assert_eq!(folder(&v, &a).name, "Games");
}

#[test]
fn moving_into_a_parent_with_a_same_named_child_is_name_conflict() {
    let (_d, mut v) = fresh();
    let games = person(&mut v, "Games", None);
    person(&mut v, "Café", Some(&games));
    let loose = agent(&mut v, "CAFÉ", None);
    let nested = agent(&mut v, "games", Some(&games));
    let before = snapshot(&v);
    for caller in CALLERS {
        let e = err(
            update(&mut v, &loose, move_under(&games), caller),
            "move CAFÉ",
        );
        assert_code(
            &e,
            "name_conflict",
            &format!("{caller:?} move CAFÉ under Games"),
        );
        let e = err(update(&mut v, &nested, to_root(), caller), "games to root");
        assert_code(
            &e,
            "name_conflict",
            &format!("{caller:?} move games to root"),
        );
    }
    assert_eq!(snapshot(&v), before);
}

// ======================================================================
// AC 3: with the default max depth 2, creating under a depth-2 folder fails
// for both callers with depth_exceeded {max_depth 2, required_depth 3}.
// ======================================================================

#[test]
fn creating_under_a_depth_two_folder_exceeds_the_default_max_for_both_callers() {
    let (_d, mut v) = fresh();
    let root = agent(&mut v, "Games", None);
    let child = agent(&mut v, "Platformers", Some(&root));
    assert_eq!(folder(&v, &child).depth, 2);
    let before = snapshot(&v);
    for caller in CALLERS {
        let e = err(
            sf::create_folder(&mut v, "Too Deep", Some(&child), caller, &clock()),
            "create at depth 3",
        );
        assert_depth(&e, 2, 3, &format!("{caller:?} create at depth 3"));
        assert_code(&e, "depth_exceeded", "code");
    }
    assert_eq!(snapshot(&v), before, "a depth failure writes nothing");
}

#[test]
fn creating_at_exactly_the_max_depth_succeeds_and_one_more_fails() {
    for max in 1..=5i64 {
        let (_d, mut v) = fresh();
        set_max(&mut v, max);
        let mut parent: Option<String> = None;
        for depth in 1..=max {
            for caller in CALLERS {
                let name = format!("{caller:?} {depth}");
                let f = mk(&mut v, &name, parent.as_deref(), caller);
                assert_eq!(f.depth, depth, "max {max}: {name}");
            }
            parent = Some(
                list(&v)
                    .folders
                    .into_iter()
                    .find(|f| f.folder.name == format!("Person {depth}"))
                    .unwrap()
                    .folder
                    .id,
            );
        }
        for caller in CALLERS {
            let e = err(
                sf::create_folder(&mut v, "Over", parent.as_deref(), caller, &clock()),
                "one past max",
            );
            assert_depth(&e, max, max + 1, &format!("max {max}, {caller:?}"));
        }
    }
}

// ======================================================================
// AC 4: moving a folder that has a child (height 2) under a root folder with
// max depth 2 fails with required_depth 3; moving it to the root succeeds.
// ======================================================================

/// P(1) / X(2) / Y(3) built under max 3, then max lowered to 2, plus a
/// separate root R. All agent-created (unpinned) so both callers may move.
fn tall_tree(v: &mut Vault) -> (String, String, String, String) {
    set_max(v, 3);
    let p = agent(v, "P", None);
    let x = agent(v, "X", Some(&p));
    let y = agent(v, "Y", Some(&x));
    let r = agent(v, "R", None);
    set_max(v, 2);
    (p, x, y, r)
}

#[test]
fn moving_a_height_two_subtree_under_a_root_folder_exceeds_max_two() {
    let (_d, mut v) = fresh();
    let (_p, x, _y, r) = tall_tree(&mut v);
    let before = snapshot(&v);
    for caller in CALLERS {
        let e = err(update(&mut v, &x, move_under(&r), caller), "move X under R");
        assert_depth(&e, 2, 3, &format!("{caller:?} move X under R"));
    }
    assert_eq!(snapshot(&v), before, "a failed move changes nothing");
}

#[test]
fn moving_a_height_two_subtree_to_the_root_succeeds() {
    for caller in CALLERS {
        let (_d, mut v) = fresh();
        let (_p, x, y, _r) = tall_tree(&mut v);
        let moved = update(&mut v, &x, to_root(), caller).unwrap();
        assert_eq!(moved.parent_id, None, "{caller:?}");
        assert_eq!(moved.depth, 1, "{caller:?}");
        assert_eq!(folder(&v, &x).parent_id, None);
        assert_eq!(folder(&v, &y).parent_id.as_deref(), Some(x.as_str()));
        assert_eq!(folder(&v, &y).depth, 2, "child depth follows the move");
    }
}

#[test]
fn moving_a_subtree_to_exactly_the_max_depth_succeeds() {
    let (_d, mut v) = fresh();
    set_max(&mut v, 3);
    let r = agent(&mut v, "R", None);
    let x = agent(&mut v, "X", None);
    let y = agent(&mut v, "Y", Some(&x));
    let moved = update(&mut v, &x, move_under(&r), Caller::Agent).unwrap();
    assert_eq!(moved.parent_id.as_deref(), Some(r.as_str()));
    assert_eq!(moved.depth, 2);
    assert_eq!(folder(&v, &y).depth, 3);
}

#[test]
fn moving_a_leaf_under_a_depth_two_folder_exceeds_max_two() {
    let (_d, mut v) = fresh();
    let r = agent(&mut v, "R", None);
    let c = agent(&mut v, "C", Some(&r));
    let leaf = agent(&mut v, "Leaf", None);
    let e = err(
        update(&mut v, &leaf, move_under(&c), Caller::Person),
        "leaf",
    );
    assert_depth(&e, 2, 3, "leaf under depth-2 folder");
    // Under the depth-1 folder it fits exactly.
    let moved = update(&mut v, &leaf, move_under(&r), Caller::Agent).unwrap();
    assert_eq!(moved.depth, 2);
}

#[test]
fn required_depth_counts_the_tallest_branch_of_the_moved_subtree() {
    let (_d, mut v) = fresh();
    set_max(&mut v, 4);
    let r = agent(&mut v, "R", None);
    let x = agent(&mut v, "X", None);
    agent(&mut v, "Short", Some(&x));
    let z = agent(&mut v, "Z", Some(&x));
    agent(&mut v, "W", Some(&z));
    set_max(&mut v, 3);
    // X has height 3 (X / Z / W); under R (depth 1) it needs depth 4.
    let e = err(update(&mut v, &x, move_under(&r), Caller::Person), "move X");
    assert_depth(&e, 3, 4, "tallest branch counts");
    // Z has height 2; under R it needs 3, which fits.
    let moved = update(&mut v, &z, move_under(&r), Caller::Agent).unwrap();
    assert_eq!(moved.depth, 2);
}

// ======================================================================
// AC 5: re-parenting a folder under itself or a descendant is folder_cycle.
// ======================================================================

#[test]
fn reparenting_a_folder_under_itself_is_folder_cycle() {
    let (_d, mut v) = fresh();
    let x = agent(&mut v, "X", None);
    let before = snapshot(&v);
    for caller in CALLERS {
        let e = err(update(&mut v, &x, move_under(&x), caller), "under itself");
        assert_code(&e, "folder_cycle", &format!("{caller:?} under itself"));
    }
    assert_eq!(snapshot(&v), before);
}

#[test]
fn reparenting_a_folder_under_its_descendant_is_folder_cycle() {
    let (_d, mut v) = fresh();
    set_max(&mut v, 5);
    let x = agent(&mut v, "X", None);
    let y = agent(&mut v, "Y", Some(&x));
    let z = agent(&mut v, "Z", Some(&y));
    let before = snapshot(&v);
    for caller in CALLERS {
        let e = err(update(&mut v, &x, move_under(&y), caller), "under child");
        assert_code(&e, "folder_cycle", &format!("{caller:?} under child"));
        let e = err(
            update(&mut v, &x, move_under(&z), caller),
            "under grandchild",
        );
        assert_code(&e, "folder_cycle", &format!("{caller:?} under grandchild"));
        let e = err(
            update(&mut v, &y, move_under(&z), caller),
            "Y under its child",
        );
        assert_code(&e, "folder_cycle", &format!("{caller:?} Y under Z"));
    }
    assert_eq!(snapshot(&v), before);
    // Moving a descendant under an ancestor's sibling branch is not a cycle.
    let moved = update(&mut v, &z, move_under(&x), Caller::Agent).unwrap();
    assert_eq!(moved.depth, 2);
}

// ======================================================================
// AC 6: delete re-parents subfolders to the parent (or root), drops the
// memberships and deletes no note; a re-parented name clash fails with
// name_conflict and changes nothing.
// ======================================================================

#[test]
fn deleting_a_folder_reparents_children_to_its_parent_and_keeps_notes() {
    let (_d, mut v) = fresh();
    set_max(&mut v, 3);
    let a = person(&mut v, "A", None);
    let b = person(&mut v, "B", Some(&a));
    let c = person(&mut v, "C", Some(&b));
    let only_b = topic(&mut v, "Only In B");
    let both = topic(&mut v, "In A And B");
    add(&mut v, &b, &only_b, Caller::Person);
    add(&mut v, &b, &both, Caller::Person);
    add(&mut v, &a, &both, Caller::Person);
    let notes_before = note_count(&v);

    sf::delete_folder(&mut v, &b, Caller::Person).unwrap();

    assert!(!folder_ids(&v).contains(&b), "B deleted");
    assert_eq!(folder(&v, &c).parent_id.as_deref(), Some(a.as_str()));
    assert_eq!(folder(&v, &c).depth, 2);
    assert_eq!(membership_rows(&v, &b, &only_b), 0);
    assert_eq!(membership_rows(&v, &b, &both), 0);
    assert_eq!(note_count(&v), notes_before, "no note deleted");
    assert_eq!(member_ids(&v, &a), BTreeSet::from([both.clone()]));
    assert!(
        unsorted_ids(&v).contains(&only_b),
        "its only folder is gone"
    );
    assert!(!unsorted_ids(&v).contains(&both));
}

#[test]
fn deleting_a_root_folder_moves_its_children_to_the_root() {
    let (_d, mut v) = fresh();
    set_max(&mut v, 3);
    let a = agent(&mut v, "A", None);
    let b = agent(&mut v, "B", Some(&a));
    let c = agent(&mut v, "C", Some(&b));
    let d = agent(&mut v, "D", Some(&a));
    sf::delete_folder(&mut v, &a, Caller::Agent).unwrap();
    assert_eq!(folder(&v, &b).parent_id, None);
    assert_eq!(folder(&v, &b).depth, 1);
    assert_eq!(folder(&v, &d).parent_id, None);
    assert_eq!(folder(&v, &c).parent_id.as_deref(), Some(b.as_str()));
    assert_eq!(folder(&v, &c).depth, 2);
    assert_eq!(folder_ids(&v), BTreeSet::from([b, c, d]));
}

#[test]
fn delete_fails_with_name_conflict_when_a_reparented_child_clashes_and_changes_nothing() {
    let (_d, mut v) = fresh();
    person(&mut v, "Games", None);
    let inbox = person(&mut v, "Inbox", None);
    person(&mut v, "games", Some(&inbox));
    person(&mut v, "Unique", Some(&inbox));
    let n = topic(&mut v, "Player Loop");
    add(&mut v, &inbox, &n, Caller::Person);
    let before = snapshot(&v);

    let e = err(
        sf::delete_folder(&mut v, &inbox, Caller::Person),
        "delete Inbox",
    );
    assert_code(&e, "name_conflict", "delete Inbox");
    assert!(
        e.to_string().to_lowercase().contains("games"),
        "message names the clash: {e}"
    );
    assert_eq!(snapshot(&v), before, "a failed delete changes nothing");

    // Non-ASCII clash one level down.
    let (_d2, mut v2) = fresh();
    let outer = person(&mut v2, "Outer", None);
    person(&mut v2, "Café", Some(&outer));
    let mid = person(&mut v2, "Mid", Some(&outer));
    set_max(&mut v2, 3);
    person(&mut v2, "CAFÉ", Some(&mid));
    let before = snapshot(&v2);
    let e = err(
        sf::delete_folder(&mut v2, &mid, Caller::Person),
        "delete Mid",
    );
    assert_code(&e, "name_conflict", "delete Mid (CAFÉ vs Café)");
    assert_eq!(snapshot(&v2), before);
}

#[test]
fn delete_succeeds_when_a_child_only_shares_the_deleted_folders_name() {
    let (_d, mut v) = fresh();
    set_max(&mut v, 3);
    let a = person(&mut v, "A", None);
    let notes_f = person(&mut v, "Notes", Some(&a));
    let child = person(&mut v, "notes", Some(&notes_f));
    sf::delete_folder(&mut v, &notes_f, Caller::Person).unwrap();
    let c = folder(&v, &child);
    assert_eq!(c.parent_id.as_deref(), Some(a.as_str()));
    assert_eq!(c.name, "notes");
    assert_eq!(c.depth, 2);
}

#[test]
fn deleting_a_missing_folder_is_not_found() {
    let (_d, mut v) = fresh();
    for caller in CALLERS {
        let e = err(
            sf::delete_folder(&mut v, &ulid::Ulid::new().to_string(), caller),
            "delete missing",
        );
        assert_code(&e, "not_found", "delete missing folder");
    }
}

// ======================================================================
// AC 7: a topic note can be in several folders, including a parent and one
// of its subfolders.
// ======================================================================

#[test]
fn a_topic_note_can_be_a_member_of_a_parent_and_its_subfolder() {
    let (_d, mut v) = fresh();
    let games = person(&mut v, "Games", None);
    let plat = person(&mut v, "Platformers", Some(&games));
    let other = agent(&mut v, "Design", None);
    let n = topic(&mut v, "Player Loop");
    add(&mut v, &games, &n, Caller::Person);
    add(&mut v, &plat, &n, Caller::Person);
    add(&mut v, &other, &n, Caller::Agent);
    for f in [&games, &plat, &other] {
        assert_eq!(
            member_ids(&v, f),
            BTreeSet::from([n.clone()]),
            "member of {f}"
        );
    }
    assert!(!unsorted_ids(&v).contains(&n));
}

// ======================================================================
// AC 8: person membership pinned, agent membership unpinned; re-adding is
// idempotent.
// ======================================================================

#[test]
fn person_membership_is_pinned_and_agent_membership_is_not() {
    let (_d, mut v) = fresh();
    let f = person(&mut v, "Games", None);
    let a = topic(&mut v, "Player Loop");
    let b = topic(&mut v, "Sleep");
    let ma = add(&mut v, &f, &a, Caller::Person);
    let mb = add(&mut v, &f, &b, Caller::Agent);
    assert_eq!(ma.smart_folder_id, f);
    assert_eq!(ma.note_id, a);
    assert!(ma.pinned);
    assert!(!ma.role_set, "already a topic");
    assert_eq!(mb.note_id, b);
    assert!(!mb.pinned);
    assert!(!mb.role_set);
    assert_eq!(member_pin(&v, &f, &a), Some(true));
    assert_eq!(member_pin(&v, &f, &b), Some(false));
}

#[test]
fn adding_an_existing_membership_again_is_idempotent() {
    let (_d, mut v) = fresh();
    let f = agent(&mut v, "Games", None);
    let a = topic(&mut v, "Player Loop");
    let b = topic(&mut v, "Sleep");
    add(&mut v, &f, &a, Caller::Person);
    let again = add(&mut v, &f, &a, Caller::Person);
    assert!(again.pinned);
    add(&mut v, &f, &b, Caller::Agent);
    let again = add(&mut v, &f, &b, Caller::Agent);
    assert!(!again.pinned);
    assert_eq!(membership_rows(&v, &f, &a), 1);
    assert_eq!(membership_rows(&v, &f, &b), 1);

    // The agent re-adding a person-pinned membership leaves it pinned.
    let v1 = version(&v, &a);
    let m = add(&mut v, &f, &a, Caller::Agent);
    assert!(m.pinned, "agent re-add keeps the person's pin");
    assert_eq!(member_pin(&v, &f, &a), Some(true));
    assert_eq!(
        version(&v, &a),
        v1,
        "re-adding a topic note does not write it"
    );
    assert_eq!(member_ids(&v, &f).len(), 2);
}

#[test]
fn agent_cannot_change_pins() {
    let (_d, mut v) = fresh();
    let pinned_f = person(&mut v, "Games", None);
    let open_f = agent(&mut v, "Inbox", None);
    let n = topic(&mut v, "Player Loop");
    add(&mut v, &open_f, &n, Caller::Person);

    let _ = sf::add_member(&mut v, &open_f, &n, Some(false), Caller::Agent, None);
    assert_eq!(
        member_pin(&v, &open_f, &n),
        Some(true),
        "agent cannot unpin a membership"
    );

    let _ = update(&mut v, &pinned_f, pin(false), Caller::Agent);
    assert!(folder(&v, &pinned_f).pinned, "agent cannot unpin a folder");
    let _ = update(&mut v, &open_f, pin(true), Caller::Agent);
    assert!(!folder(&v, &open_f).pinned, "agent cannot pin a folder");
}

// ======================================================================
// AC 9: a person adding a role-less non-daily note sets role: topic, keeps
// the other frontmatter keys and reports role_set: true.
// ======================================================================

#[test]
fn person_adding_a_roleless_note_sets_role_topic_and_keeps_other_keys() {
    let (_d, mut v) = fresh();
    let f = agent(&mut v, "Games", None);
    let n = note_with(
        &mut v,
        "Old note",
        "Some old thoughts.",
        json!({"tags": ["games"], "source": "app", "status": "draft"}),
    );
    assert_eq!(version(&v, &n), 1);
    let m = sf::add_member(&mut v, &f, &n, None, Caller::Person, None).unwrap();
    assert!(m.role_set, "role_set reported");
    assert!(m.pinned, "person membership pinned (Q3)");
    assert_eq!(
        frontmatter(&v, &n),
        json!({"tags": ["games"], "source": "app", "status": "draft", "role": "topic"})
    );
    assert_eq!(
        version(&v, &n),
        2,
        "version bumped through the person write path"
    );
    assert_eq!(member_pin(&v, &f, &n), Some(true));

    // Re-adding: already a topic now, nothing to set.
    let again = sf::add_member(&mut v, &f, &n, None, Caller::Person, None).unwrap();
    assert!(!again.role_set);
    assert_eq!(version(&v, &n), 2);
}

#[test]
fn person_adding_a_roleless_note_reindexes_it() {
    let (_d, mut v) = fresh();
    let f = person(&mut v, "Games", None);
    let n = note_with(
        &mut v,
        "Jump Arc",
        "The jump arc feels floaty at the apex.",
        json!({}),
    );
    let chunks = |v: &Vault| -> i64 {
        v.connection_ref()
            .query_row("SELECT COUNT(*) FROM chunks WHERE note_id = ?", [&n], |r| {
                r.get(0)
            })
            .unwrap()
    };
    assert_eq!(chunks(&v), 0, "core create_note does not index");
    sf::add_member(&mut v, &f, &n, None, Caller::Person, None).unwrap();
    assert!(chunks(&v) > 0, "the role change reindexes the note (D8)");
}

// ======================================================================
// AC 10: an agent adding a role-less note, or anyone adding a daily note,
// fails with role_rule and writes nothing.
// ======================================================================

#[test]
fn agent_adding_a_roleless_or_non_topic_note_is_role_rule_and_writes_nothing() {
    let (_d, mut v) = fresh();
    let pinned_f = person(&mut v, "Games", None);
    let open_f = agent(&mut v, "Inbox", None);
    let plain = roleless(&mut v, "Old note");
    let project = note_with(&mut v, "Project X", "x", json!({"role": "project"}));
    let before = snapshot(&v);
    for f in [&pinned_f, &open_f] {
        for n in [&plain, &project] {
            let e = err(
                sf::add_member(&mut v, f, n, None, Caller::Agent, None),
                "agent add non-topic",
            );
            assert_code(&e, "role_rule", "agent add non-topic");
            assert!(e.to_string().contains("role"), "message mentions role: {e}");
        }
    }
    assert_eq!(snapshot(&v), before, "nothing written");
}

#[test]
fn adding_a_daily_note_is_role_rule_for_every_caller() {
    let (_d, mut v) = fresh();
    let f = person(&mut v, "Games", None);
    let d = daily(&mut v, "2026-10-01");
    let before = snapshot(&v);
    for caller in CALLERS {
        for pinned in [None, Some(true), Some(false)] {
            let e = err(
                sf::add_member(&mut v, &f, &d, pinned, caller, None),
                "add daily note",
            );
            assert_code(&e, "role_rule", &format!("{caller:?} add daily"));
            assert!(e.to_string().contains("role"), "message mentions role: {e}");
        }
    }
    assert_eq!(snapshot(&v), before, "nothing written");
    assert_eq!(frontmatter(&v, &d), json!({"role": "daily"}));
}

#[test]
fn adding_with_a_missing_folder_or_note_is_not_found() {
    let (_d, mut v) = fresh();
    let f = person(&mut v, "Games", None);
    let n = topic(&mut v, "Player Loop");
    let missing = ulid::Ulid::new().to_string();
    for caller in CALLERS {
        let e = err(
            sf::add_member(&mut v, &missing, &n, None, caller, None),
            "folder",
        );
        assert_code(&e, "not_found", "add to missing folder");
        let e = err(
            sf::add_member(&mut v, &f, &missing, None, caller, None),
            "note",
        );
        assert_code(&e, "not_found", "add missing note");
    }
    assert!(member_ids(&v, &f).is_empty());
}

// ======================================================================
// AC 11: a person rename or re-parent of an agent folder pins it; explicit
// pinned: false in the same call leaves it unpinned; pins toggle.
// ======================================================================

#[test]
fn person_rename_of_an_agent_folder_pins_it() {
    let (_d, mut v) = fresh();
    let f = agent(&mut v, "Inbox", None);
    let later = FakeClock::at(T0 + 5_000);
    let got = sf_update(&mut v, &f, rename("Triage"), Caller::Person, &later).unwrap();
    assert_eq!(got.name, "Triage");
    assert!(got.pinned, "person rename pins");
    assert_eq!(got.created_at, T0, "created_at unchanged");
    assert_eq!(got.updated_at, T0 + 5_000, "updated_at from the clock");
    assert_eq!(folder(&v, &f), got);
}

#[test]
fn person_reparent_of_an_agent_folder_pins_it() {
    let (_d, mut v) = fresh();
    let r = agent(&mut v, "R", None);
    let x = agent(&mut v, "X", None);
    let got = update(&mut v, &x, move_under(&r), Caller::Person).unwrap();
    assert!(got.pinned, "person re-parent pins");
    assert!(!folder(&v, &r).pinned, "the new parent is untouched");
    let y = agent(&mut v, "Y", Some(&r));
    let got = update(&mut v, &y, to_root(), Caller::Person).unwrap();
    assert!(got.pinned, "person move to root pins");
}

#[test]
fn explicit_pinned_false_in_the_same_person_call_leaves_it_unpinned() {
    let (_d, mut v) = fresh();
    let r = agent(&mut v, "R", None);
    let x = agent(&mut v, "X", None);
    let got = update(
        &mut v,
        &x,
        FolderUpdate {
            name: Some("X2".into()),
            parent: Some(NewParent::Folder(r.clone())),
            pinned: Some(false),
        },
        Caller::Person,
    )
    .unwrap();
    assert_eq!(got.name, "X2");
    assert_eq!(got.parent_id.as_deref(), Some(r.as_str()));
    assert!(!got.pinned);
    assert!(!folder(&v, &x).pinned);
}

#[test]
fn person_toggles_the_folder_pin() {
    let (_d, mut v) = fresh();
    let f = person(&mut v, "Games", None);
    let later = FakeClock::at(T0 + 9);
    let got = sf_update(&mut v, &f, pin(false), Caller::Person, &later).unwrap();
    assert!(!got.pinned);
    assert_eq!(got.name, "Games");
    assert_eq!(got.parent_id, None);
    assert_eq!(got.updated_at, T0 + 9);
    assert!(!folder(&v, &f).pinned);
    later.set(T0 + 10);
    let got = sf_update(&mut v, &f, pin(true), Caller::Person, &later).unwrap();
    assert!(got.pinned);
    assert_eq!(got.updated_at, T0 + 10);
    assert!(folder(&v, &f).pinned);
}

#[test]
fn person_toggles_the_membership_pin_through_add() {
    let (_d, mut v) = fresh();
    let f = agent(&mut v, "Games", None);
    let n = topic(&mut v, "Player Loop");
    let m = sf::add_member(&mut v, &f, &n, Some(false), Caller::Person, None).unwrap();
    assert!(!m.pinned, "explicit pinned false on create");
    assert_eq!(member_pin(&v, &f, &n), Some(false));
    let m = sf::add_member(&mut v, &f, &n, Some(true), Caller::Person, None).unwrap();
    assert!(m.pinned);
    assert_eq!(member_pin(&v, &f, &n), Some(true));
    let m = sf::add_member(&mut v, &f, &n, Some(false), Caller::Person, None).unwrap();
    assert!(!m.pinned);
    assert_eq!(member_pin(&v, &f, &n), Some(false));
    // A plain person add of an agent membership pins it (Req 41).
    let m = sf::add_member(&mut v, &f, &n, None, Caller::Person, None).unwrap();
    assert!(m.pinned);
    assert_eq!(membership_rows(&v, &f, &n), 1);
}

// ======================================================================
// AC 12: on a pinned folder the agent can add memberships, but rename,
// re-parent and delete fail with pinned_rule {item: folder id}, message
// naming the folder.
// ======================================================================

#[test]
fn agent_can_add_members_to_a_pinned_folder() {
    let (_d, mut v) = fresh();
    let f = person(&mut v, "Games", None);
    let n = topic(&mut v, "Player Loop");
    let m = add(&mut v, &f, &n, Caller::Agent);
    assert!(!m.pinned);
    assert_eq!(member_pin(&v, &f, &n), Some(false));
}

#[test]
fn agent_rename_reparent_and_delete_of_a_pinned_folder_are_pinned_rule() {
    let (_d, mut v) = fresh();
    let games = person(&mut v, "Games", None);
    let work = agent(&mut v, "Work", None);
    let nested = person(&mut v, "Platformers", Some(&work));
    let n = topic(&mut v, "Player Loop");
    add(&mut v, &games, &n, Caller::Agent);
    let before = snapshot(&v);

    let e = err(
        update(&mut v, &games, rename("Gaming"), Caller::Agent),
        "rename",
    );
    assert_pinned(&e, &games, "Games", "agent rename of pinned folder");
    let e = err(
        update(&mut v, &games, move_under(&work), Caller::Agent),
        "move",
    );
    assert_pinned(&e, &games, "Games", "agent re-parent of pinned folder");
    let e = err(update(&mut v, &nested, to_root(), Caller::Agent), "to root");
    assert_pinned(
        &e,
        &nested,
        "Platformers",
        "agent move of pinned folder to root",
    );
    let e = err(sf::delete_folder(&mut v, &games, Caller::Agent), "delete");
    assert_pinned(&e, &games, "Games", "agent delete of pinned folder");
    assert_code(&e, "pinned_rule", "code");

    assert_eq!(snapshot(&v), before, "nothing changes");
}

// ======================================================================
// AC 13: on a pinned folder the agent removing any membership, including one
// it added, fails with pinned_rule.
// ======================================================================

#[test]
fn agent_removing_any_membership_from_a_pinned_folder_is_pinned_rule() {
    let (_d, mut v) = fresh();
    let f = person(&mut v, "Games", None);
    let mine = topic(&mut v, "Agent Topic");
    let theirs = topic(&mut v, "Person Topic");
    add(&mut v, &f, &mine, Caller::Agent);
    add(&mut v, &f, &theirs, Caller::Person);
    let before = snapshot(&v);

    let e = err(
        sf::remove_member(&mut v, &f, &mine, Caller::Agent),
        "remove own",
    );
    assert_pinned(&e, &f, "Games", "agent removes its own membership");
    let e = err(
        sf::remove_member(&mut v, &f, &theirs, Caller::Agent),
        "remove",
    );
    assert_code(&e, "pinned_rule", "agent removes the person's membership");

    assert_eq!(snapshot(&v), before);
    assert_eq!(member_ids(&v, &f).len(), 2);
}

// ======================================================================
// AC 14: an unpinned folder holding a pinned membership: the agent can rename
// and re-parent it; removing that membership is pinned_rule {item:
// "<folder>/<note>"}; deleting the folder is pinned_rule.
// ======================================================================

fn inbox_with_pinned_member(v: &mut Vault) -> (String, String, String, String) {
    let inbox = agent(v, "Inbox", None);
    let target = agent(v, "Archive", None);
    let pinned_n = topic(v, "Player Loop");
    let open_n = topic(v, "Sleep");
    add(v, &inbox, &pinned_n, Caller::Person);
    add(v, &inbox, &open_n, Caller::Agent);
    (inbox, target, pinned_n, open_n)
}

#[test]
fn agent_can_rename_and_reparent_an_unpinned_folder_holding_a_pinned_membership() {
    let (_d, mut v) = fresh();
    let (inbox, target, pinned_n, _open) = inbox_with_pinned_member(&mut v);
    let got = update(&mut v, &inbox, rename("Triage"), Caller::Agent).unwrap();
    assert_eq!(got.name, "Triage");
    assert!(!got.pinned, "agent edits never pin");
    let got = update(&mut v, &inbox, move_under(&target), Caller::Agent).unwrap();
    assert_eq!(got.parent_id.as_deref(), Some(target.as_str()));
    assert_eq!(got.depth, 2);
    assert_eq!(
        member_pin(&v, &inbox, &pinned_n),
        Some(true),
        "pinned member kept"
    );
}

#[test]
fn agent_removing_a_pinned_membership_is_pinned_rule_naming_it() {
    let (_d, mut v) = fresh();
    let (inbox, _t, pinned_n, open_n) = inbox_with_pinned_member(&mut v);
    let before = snapshot(&v);
    let e = err(
        sf::remove_member(&mut v, &inbox, &pinned_n, Caller::Agent),
        "remove",
    );
    assert_pinned(
        &e,
        &format!("{inbox}/{pinned_n}"),
        "Player Loop",
        "agent removes a pinned membership",
    );
    assert_eq!(snapshot(&v), before);
    // The unpinned membership beside it can go.
    sf::remove_member(&mut v, &inbox, &open_n, Caller::Agent).unwrap();
    assert_eq!(member_ids(&v, &inbox), BTreeSet::from([pinned_n]));
}

#[test]
fn agent_deleting_an_unpinned_folder_holding_a_pinned_membership_is_pinned_rule() {
    let (_d, mut v) = fresh();
    let (inbox, _t, _p, _o) = inbox_with_pinned_member(&mut v);
    let before = snapshot(&v);
    let e = err(sf::delete_folder(&mut v, &inbox, Caller::Agent), "delete");
    assert_code(
        &e,
        "pinned_rule",
        "agent delete of folder with pinned member",
    );
    assert_eq!(snapshot(&v), before);
}

// ======================================================================
// AC 15: unpinned folders and memberships are fully manageable by the agent
// within the depth limit.
// ======================================================================

#[test]
fn agent_manages_unpinned_folders_and_memberships_within_the_depth_limit() {
    let (_d, mut v) = fresh();
    let a = agent(&mut v, "Games", None);
    let b = agent(&mut v, "Platformers", Some(&a));
    let c = agent(&mut v, "Design", None);
    let n = topic(&mut v, "Player Loop");

    let got = update(&mut v, &b, rename("Platform Games"), Caller::Agent).unwrap();
    assert_eq!(got.name, "Platform Games");
    assert!(!got.pinned);
    let got = update(&mut v, &b, move_under(&c), Caller::Agent).unwrap();
    assert_eq!(got.parent_id.as_deref(), Some(c.as_str()));
    let got = update(&mut v, &b, to_root(), Caller::Agent).unwrap();
    assert_eq!(got.parent_id, None);
    assert_eq!(got.depth, 1);

    let m = add(&mut v, &b, &n, Caller::Agent);
    assert!(!m.pinned);
    sf::remove_member(&mut v, &b, &n, Caller::Agent).unwrap();
    assert!(member_ids(&v, &b).is_empty());

    add(&mut v, &a, &n, Caller::Agent);
    sf::delete_folder(&mut v, &a, Caller::Agent).unwrap();
    assert!(!folder_ids(&v).contains(&a));
    assert!(unsorted_ids(&v).contains(&n), "note kept, now unsorted");

    // Still bound by the depth limit.
    let deep = agent(&mut v, "Deep", Some(&c));
    let e = err(
        sf::create_folder(&mut v, "Deeper", Some(&deep), Caller::Agent, &clock()),
        "agent past max",
    );
    assert_depth(&e, 2, 3, "agent past max");
}

#[test]
fn removing_a_missing_membership_is_not_found() {
    let (_d, mut v) = fresh();
    let f = agent(&mut v, "Games", None);
    let n = topic(&mut v, "Player Loop");
    for caller in CALLERS {
        let e = err(sf::remove_member(&mut v, &f, &n, caller), "remove missing");
        assert_code(&e, "not_found", "remove a non-member");
    }
}

// ======================================================================
// AC 16: none of the operations in ACs 12–14 is blocked for the person.
// ======================================================================

#[test]
fn person_is_never_blocked_by_pinning() {
    let (_d, mut v) = fresh();
    // AC 12/13 setup: a pinned folder with an agent and a person membership.
    let games = person(&mut v, "Games", None);
    let work = person(&mut v, "Work", None);
    let a_n = topic(&mut v, "Agent Topic");
    let p_n = topic(&mut v, "Person Topic");
    add(&mut v, &games, &a_n, Caller::Agent);
    add(&mut v, &games, &p_n, Caller::Person);
    sf::remove_member(&mut v, &games, &a_n, Caller::Person).unwrap();
    sf::remove_member(&mut v, &games, &p_n, Caller::Person).unwrap();
    assert!(member_ids(&v, &games).is_empty());
    let got = update(&mut v, &games, rename("Gaming"), Caller::Person).unwrap();
    assert_eq!(got.name, "Gaming");
    assert!(got.pinned);
    let got = update(&mut v, &games, move_under(&work), Caller::Person).unwrap();
    assert_eq!(got.parent_id.as_deref(), Some(work.as_str()));
    let got = update(&mut v, &games, to_root(), Caller::Person).unwrap();
    assert_eq!(got.parent_id, None);
    sf::delete_folder(&mut v, &games, Caller::Person).unwrap();
    assert!(!folder_ids(&v).contains(&games));

    // AC 14 setup: an unpinned folder holding a pinned membership.
    let (inbox, _t, pinned_n, _o) = inbox_with_pinned_member(&mut v);
    sf::remove_member(&mut v, &inbox, &pinned_n, Caller::Person).unwrap();
    assert_eq!(membership_rows(&v, &inbox, &pinned_n), 0);
    add(&mut v, &inbox, &pinned_n, Caller::Person);
    sf::delete_folder(&mut v, &inbox, Caller::Person).unwrap();
    assert!(!folder_ids(&v).contains(&inbox));
    assert_eq!(membership_rows(&v, &inbox, &pinned_n), 0);
}

// ======================================================================
// AC 17: smart_folder_max_depth settings.
// ======================================================================

#[test]
fn max_depth_reads_two_when_no_row_exists() {
    let (_d, mut v) = fresh();
    assert_eq!(
        vault_settings::smart_folder_max_depth(&v).unwrap(),
        2,
        "seeded"
    );
    v.connection_ref()
        .execute("DELETE FROM vault_settings", [])
        .unwrap();
    assert_eq!(vault_settings::smart_folder_max_depth(&v).unwrap(), 2);
    assert_eq!(
        vault_settings::get_setting(&v, "smart_folder_max_depth").unwrap(),
        2
    );
    assert_eq!(list(&v).max_depth, 2);
    // And the default is enforced.
    let r = agent(&mut v, "R", None);
    let c = agent(&mut v, "C", Some(&r));
    let e = err(
        sf::create_folder(&mut v, "D", Some(&c), Caller::Person, &clock()),
        "default enforced",
    );
    assert_depth(&e, 2, 3, "default max without a row");
}

#[test]
fn setting_max_depth_one_to_five_is_stored() {
    let (_d, mut v) = fresh();
    for n in [3i64, 1, 5, 4, 2] {
        let got =
            vault_settings::set_setting(&mut v, "smart_folder_max_depth", &n.to_string()).unwrap();
        assert_eq!(got, n);
        assert_eq!(vault_settings::smart_folder_max_depth(&v).unwrap(), n);
        assert_eq!(
            vault_settings::get_setting(&v, "smart_folder_max_depth").unwrap(),
            n
        );
        assert_eq!(list(&v).max_depth, n);
        let raw: i64 = v
            .connection_ref()
            .query_row(
                "SELECT CAST(value AS INTEGER) FROM vault_settings WHERE key = 'smart_folder_max_depth'",
                [],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(raw, n, "stored in vault_settings");
    }
    // Stored when no row existed yet.
    v.connection_ref()
        .execute("DELETE FROM vault_settings", [])
        .unwrap();
    set_max(&mut v, 4);
    assert_eq!(vault_settings::smart_folder_max_depth(&v).unwrap(), 4);
}

#[test]
fn invalid_max_depth_values_and_unknown_keys_are_setting_invalid() {
    let (_d, mut v) = fresh();
    set_max(&mut v, 3);
    let before = snapshot(&v);
    for bad in ["0", "6", "-1", "10", "abc", "2.5", "", "3x"] {
        let e = err(
            vault_settings::set_setting(&mut v, "smart_folder_max_depth", bad),
            &format!("value {bad:?}"),
        );
        assert_code(&e, "setting_invalid", &format!("value {bad:?}"));
    }
    let e = err(
        vault_settings::set_setting(&mut v, "max_depth", "3"),
        "unknown key set",
    );
    assert_code(&e, "setting_invalid", "unknown key set");
    let e = err(vault_settings::get_setting(&v, "theme"), "unknown key get");
    assert_code(&e, "setting_invalid", "unknown key get");
    assert_eq!(snapshot(&v), before, "invalid settings store nothing");
    assert_eq!(vault_settings::smart_folder_max_depth(&v).unwrap(), 3);
}

#[test]
fn lowering_max_depth_leaves_existing_deeper_folders_in_place() {
    let (_d, mut v) = fresh();
    set_max(&mut v, 3);
    let a = person(&mut v, "A", None);
    let b = person(&mut v, "B", Some(&a));
    let c = person(&mut v, "C", Some(&b));
    set_max(&mut v, 1);
    let l = list(&v);
    assert_eq!(l.max_depth, 1);
    assert_eq!(l.folders.len(), 3);
    assert_eq!(folder(&v, &b).depth, 2);
    assert_eq!(folder(&v, &c).depth, 3);
    assert_eq!(folder(&v, &c).parent_id.as_deref(), Some(b.as_str()));
    // Renames are not depth-checked, so the deep folder stays editable.
    let got = update(&mut v, &c, rename("C2"), Caller::Person).unwrap();
    assert_eq!(got.depth, 3);
    // New creates and re-parents follow the lower maximum.
    let e = err(
        sf::create_folder(&mut v, "New", Some(&a), Caller::Person, &clock()),
        "create under the lowered max",
    );
    assert_depth(&e, 1, 2, "create under lowered max");
}

// ======================================================================
// AC 18: deleting a topic note removes its memberships.
// ======================================================================

#[test]
fn deleting_a_topic_note_removes_its_memberships() {
    let (_d, mut v) = fresh();
    let f = person(&mut v, "Games", None);
    let g = agent(&mut v, "Design", None);
    let n = topic(&mut v, "Player Loop");
    let keep = topic(&mut v, "Sleep");
    add(&mut v, &f, &n, Caller::Person);
    add(&mut v, &g, &n, Caller::Agent);
    add(&mut v, &f, &keep, Caller::Person);
    notes::delete_note(&mut v, &NoteId::parse(&n).unwrap()).unwrap();
    assert_eq!(membership_rows(&v, &f, &n), 0);
    assert_eq!(membership_rows(&v, &g, &n), 0);
    assert_eq!(member_ids(&v, &f), BTreeSet::from([keep]));
    assert!(member_ids(&v, &g).is_empty());
}

// ======================================================================
// Listing (shared by AC 19 and #14's `memex folder ls`).
// ======================================================================

#[test]
fn list_reports_members_and_unsorted_non_daily_notes() {
    let (_d, mut v) = fresh();
    let games = person(&mut v, "Games", None);
    let plat = agent(&mut v, "Platformers", Some(&games));
    let member = topic(&mut v, "Player Loop");
    let lone_topic = topic(&mut v, "Sleep");
    let plain = roleless(&mut v, "Old note");
    let day = daily(&mut v, "2026-10-01");
    add(&mut v, &plat, &member, Caller::Agent);

    let l = list(&v);
    assert_eq!(l.max_depth, 2);
    assert_eq!(l.folders.len(), 2);
    let p = listed(&v, &plat);
    assert_eq!(p.folder.parent_id.as_deref(), Some(games.as_str()));
    assert_eq!(p.folder.depth, 2);
    assert!(!p.folder.pinned);
    assert_eq!(p.members.len(), 1);
    assert_eq!(p.members[0].note_id, member);
    assert_eq!(p.members[0].title, "Player Loop");
    assert!(!p.members[0].pinned);
    assert!(listed(&v, &games).members.is_empty());
    assert!(listed(&v, &games).folder.pinned);

    let unsorted: BTreeSet<(String, String)> = l
        .unsorted
        .into_iter()
        .map(|u| (u.note_id, u.title))
        .collect();
    assert_eq!(
        unsorted,
        BTreeSet::from([
            (lone_topic, "Sleep".to_string()),
            (plain, "Old note".to_string()),
        ]),
        "unsorted = non-daily notes with no membership (not {day})"
    );
}

// ======================================================================
// Implementer additions: lead rulings and behaviour beyond the ACs.
// ======================================================================

#[test]
fn an_update_that_changes_nothing_writes_nothing() {
    let (_d, mut v) = fresh();
    let open_f = agent(&mut v, "Inbox", None);
    let pinned_f = person(&mut v, "Games", None);
    let later = FakeClock::at(T0 + 1_000);
    // The agent's `pinned` is ignored, so these change nothing.
    let got = sf_update(&mut v, &open_f, pin(true), Caller::Agent, &later).unwrap();
    assert_eq!(got.updated_at, T0, "no write, no updated_at bump");
    let got = sf_update(&mut v, &pinned_f, pin(false), Caller::Agent, &later).unwrap();
    assert!(got.pinned);
    assert_eq!(got.updated_at, T0);
    // Re-pinning an already pinned folder is a person no-op too.
    let got = sf_update(&mut v, &pinned_f, pin(true), Caller::Person, &later).unwrap();
    assert_eq!(got.updated_at, T0);
    let got = sf_update(
        &mut v,
        &pinned_f,
        FolderUpdate::default(),
        Caller::Person,
        &later,
    )
    .unwrap();
    assert_eq!(folder(&v, &pinned_f), got);
    assert_eq!(got.updated_at, T0);
}

#[test]
fn agent_may_delete_an_unpinned_folder_whose_child_folder_is_pinned() {
    let (_d, mut v) = fresh();
    let outer = agent(&mut v, "Outer", None);
    let kept = person(&mut v, "Kept", Some(&outer));
    sf::delete_folder(&mut v, &outer, Caller::Agent).unwrap();
    let k = folder(&v, &kept);
    assert_eq!(k.parent_id, None, "the pinned child moves up, not away");
    assert!(k.pinned);
    assert_eq!(folder_ids(&v), BTreeSet::from([kept]));
}

#[test]
fn agent_may_move_an_unpinned_folder_into_a_pinned_folder() {
    let (_d, mut v) = fresh();
    let pinned_f = person(&mut v, "Games", None);
    let open_f = agent(&mut v, "Inbox", None);
    let got = update(&mut v, &open_f, move_under(&pinned_f), Caller::Agent).unwrap();
    assert_eq!(got.parent_id.as_deref(), Some(pinned_f.as_str()));
    assert!(!got.pinned);
}

#[test]
fn agent_delete_blocked_by_a_pinned_membership_names_it() {
    let (_d, mut v) = fresh();
    let (inbox, _t, pinned_n, _o) = inbox_with_pinned_member(&mut v);
    let e = err(sf::delete_folder(&mut v, &inbox, Caller::Agent), "delete");
    assert_pinned(
        &e,
        &format!("{inbox}/{pinned_n}"),
        "Player Loop",
        "delete blocked by a pinned membership",
    );
}

#[test]
fn person_adding_a_note_with_another_role_is_role_rule() {
    let (_d, mut v) = fresh();
    let f = person(&mut v, "Games", None);
    let project = note_with(&mut v, "Project X", "x", json!({"role": "project"}));
    let before = snapshot(&v);
    let e = err(
        sf::add_member(&mut v, &f, &project, None, Caller::Person, None),
        "person add project",
    );
    assert_code(&e, "role_rule", "person add a note whose role is not topic");
    assert_eq!(snapshot(&v), before, "the role is never overwritten");
}

#[test]
fn a_corrupt_stored_max_depth_is_setting_invalid() {
    let (_d, v) = fresh();
    v.connection_ref()
        .execute(
            "UPDATE vault_settings SET value = 'deep' WHERE key = 'smart_folder_max_depth'",
            [],
        )
        .unwrap();
    let e = err(vault_settings::smart_folder_max_depth(&v), "corrupt value");
    assert_code(&e, "setting_invalid", "corrupt stored value");
}

#[test]
fn link_kinds_list_built_ins_first_then_used_kinds_once() {
    let (_d, mut v) = fresh();
    let built_ins = ["references", "extends", "contradicts", "example-of"];
    assert_eq!(vault_settings::link_kinds(&v).unwrap(), built_ins);
    note_with(&mut v, "Target", "Target body.", json!({}));
    let body = "See [[Target]], [[Target~zeta-kind]] and [[Target~alpha-kind]].";
    let source = note_with(&mut v, "Source", body, json!({}));
    memex_core::indexer::reindex_note(v.connection_mut(), &source, body, None).unwrap();
    let mut expected = built_ins.to_vec();
    expected.extend(["alpha-kind", "zeta-kind"]);
    assert_eq!(vault_settings::link_kinds(&v).unwrap(), expected);
}
