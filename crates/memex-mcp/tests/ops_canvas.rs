//! WI #73 (R1): the canvas ops in `memex_mcp::ops::canvas` (D2), called
//! directly on temp vaults.
//!
//! - AC 3: new, ls, get, rename, rm, add, remove and move return typed
//!   structs whose fields equal what `memex canvas` prints.
//! - AC 7: the writes are stamped with the passed clock.

use std::path::PathBuf;
use std::process::{Command, Output, Stdio};

use memex_core::canvas as core_canvas;
use memex_core::notes::{self, CreateNote};
use memex_core::{indexer, Caller, CanvasId, Clock, SystemClock, Vault};
use memex_mcp::cli;
use memex_mcp::ops::canvas::{
    self as ops, AddInput, GetInput, LsInput, MoveInput, NewInput, RemoveInput, RenameInput,
    RmInput,
};
use serde_json::{json, Value};
use tempfile::TempDir;

/// A well-formed ULID that no test vault contains.
const ABSENT_ULID: &str = "01J9Z8Y7X6W5V4T3S2R1Q0P9N8";

const T0: i64 = 1_000_000_000_000;
const T1: i64 = 1_000_000_123_456;

struct FixedClock(i64);

impl Clock for FixedClock {
    fn now_ms(&self) -> i64 {
        self.0
    }
}

struct Fx {
    _dir: TempDir,
    path: PathBuf,
    vault: Vault,
}

impl Fx {
    fn new() -> Self {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("vault");
        let vault = Vault::create(&path).unwrap();
        Fx {
            _dir: dir,
            path,
            vault,
        }
    }

    fn v(&self) -> &str {
        self.path.to_str().unwrap()
    }

    fn note(&mut self, title: &str, body: &str) -> String {
        let note = notes::create_note_as(
            &mut self.vault,
            CreateNote {
                title: Some(title.into()),
                content_md: body.into(),
                frontmatter: None,
            },
            Caller::Person,
        )
        .unwrap();
        indexer::reindex_note(
            self.vault.connection_mut(),
            note.id.as_str(),
            &note.content_md,
            None,
        )
        .unwrap();
        note.id.to_string()
    }

    /// A canvas made through core, with `notes` placed at (i, 2i).
    fn canvas(&mut self, title: &str, notes: &[&str]) -> String {
        let c = core_canvas::create_canvas(&mut self.vault, title).unwrap();
        for (i, n) in notes.iter().enumerate() {
            core_canvas::add_to_canvas(&mut self.vault, &c.id, n, i as f64, 2.0 * i as f64)
                .unwrap();
        }
        c.id.to_string()
    }

    fn detail(&self, id: &str) -> core_canvas::CanvasDetail {
        core_canvas::get_canvas(&self.vault, &CanvasId::parse(id).unwrap()).unwrap()
    }
}

fn cli(args: &[&str]) -> Output {
    Command::new(env!("CARGO_BIN_EXE_memex"))
        .args(args)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .output()
        .expect("run memex")
}

fn cli_json(args: &[&str]) -> Value {
    let out = cli(args);
    assert!(
        out.status.success(),
        "memex {args:?}: {}",
        String::from_utf8_lossy(&out.stderr)
    );
    serde_json::from_slice(&out.stdout).expect("stdout JSON")
}

fn cli_err(args: &[&str]) -> Value {
    let out = cli(args);
    assert_eq!(out.status.code(), Some(1), "memex {args:?}");
    serde_json::from_slice(&out.stderr).expect("stderr JSON")
}

fn keys(v: &Value) -> Vec<String> {
    let mut k: Vec<String> = v.as_object().unwrap().keys().cloned().collect();
    k.sort();
    k
}

// ---------- new ----------

#[test]
fn ops_canvas_new_returns_the_canvas_stamped_with_the_clock() {
    let mut f = Fx::new();
    let out = ops::new(
        &mut f.vault,
        NewInput {
            title: "Board".into(),
        },
        &FixedClock(T0),
        None,
    )
    .unwrap();
    assert_eq!(out.vault_id, f.vault.vault_id());
    assert_eq!(out.title, "Board");
    assert_eq!(out.version, 1);
    assert_eq!(out.created_at, T0);
    assert_eq!(out.updated_at, T0);
    let stored = f.detail(&out.canvas_id).canvas;
    assert_eq!(stored.title, "Board");
    assert_eq!(stored.created_at, T0);

    let cli_out = cli_json(&["canvas", "new", "--vault", f.v(), "--title", "Other"]);
    assert_eq!(keys(&serde_json::to_value(&out).unwrap()), keys(&cli_out));
}

#[test]
fn ops_canvas_new_with_a_taken_title_is_title_conflict() {
    let mut f = Fx::new();
    let existing = f.canvas("Board", &[]);
    let err = ops::new(
        &mut f.vault,
        NewInput {
            title: "Board".into(),
        },
        &SystemClock,
        None,
    )
    .unwrap_err();
    let got = cli::error_json(&err);
    assert_eq!(got["error"]["code"], "title_conflict", "{got}");
    assert_eq!(got["error"]["existing_id"], json!(existing));
    assert_eq!(
        got,
        cli_err(&["canvas", "new", "--vault", f.v(), "--title", "Board"])
    );
}

// ---------- ls / get ----------

#[test]
fn ops_canvas_ls_equals_the_cli_json() {
    let mut f = Fx::new();
    let a = f.note("Alpha", "a\n");
    let b = f.note("Beta", "b\n");
    let one = f.canvas("One", &[&a, &b]);
    f.canvas("Two", &[]);
    let out = ops::ls(&mut f.vault, LsInput, &SystemClock, None).unwrap();
    assert_eq!(out.vault_id, f.vault.vault_id());
    assert_eq!(out.canvases.len(), 2);
    let row = out.canvases.iter().find(|c| c.canvas_id == one).unwrap();
    assert_eq!(row.title, "One");
    assert_eq!(row.node_count, 2);
    assert_eq!(row.version, 3);
    assert_eq!(
        serde_json::to_value(&out).unwrap(),
        cli_json(&["canvas", "ls", "--vault", f.v()])
    );
}

#[test]
fn ops_canvas_get_returns_nodes_and_edges_equal_to_the_cli_json() {
    let mut f = Fx::new();
    let b = f.note("Beta", "b\n");
    let a = f.note("Alpha", "See [[Beta~extends|more]].\n");
    let c = f.canvas("Board", &[&a, &b]);
    let out = ops::get(
        &mut f.vault,
        GetInput {
            canvas_id: c.clone(),
        },
        &SystemClock,
        None,
    )
    .unwrap();
    assert_eq!(out.canvas_id, c);
    assert_eq!(out.title, "Board");
    assert_eq!(out.version, 3);
    assert_eq!(out.nodes.len(), 2);
    let na = out.nodes.iter().find(|n| n.note_id == a).unwrap();
    assert_eq!((na.note_title.as_str(), na.x, na.y), ("Alpha", 0.0, 0.0));
    let nb = out.nodes.iter().find(|n| n.note_id == b).unwrap();
    assert_eq!((nb.x, nb.y, nb.z_order), (1.0, 2.0, 0));
    assert_eq!(out.edges.len(), 1);
    let e = &out.edges[0];
    assert_eq!(
        (e.from_note_id.as_str(), e.to_note_id.as_str()),
        (a.as_str(), b.as_str())
    );
    assert_eq!(e.kind, "extends");
    assert_eq!(e.label.as_deref(), Some("more"));
    assert_eq!(e.link_text, "Beta");
    assert_eq!(e.source, "inline_body");
    assert_eq!(
        serde_json::to_value(&out).unwrap(),
        cli_json(&["canvas", "get", "--vault", f.v(), "--canvas-id", &c])
    );
}

#[test]
fn ops_canvas_get_unknown_and_malformed_ids_map_like_the_cli() {
    let mut f = Fx::new();
    for id in [ABSENT_ULID, "nope"] {
        let err = ops::get(
            &mut f.vault,
            GetInput {
                canvas_id: id.into(),
            },
            &SystemClock,
            None,
        )
        .unwrap_err();
        assert_eq!(
            cli::error_json(&err),
            cli_err(&["canvas", "get", "--vault", f.v(), "--canvas-id", id]),
            "{id}"
        );
    }
}

// ---------- rename / rm ----------

#[test]
fn ops_canvas_rename_returns_the_new_title_version_and_clock_stamp() {
    let mut f = Fx::new();
    let c = f.canvas("Board", &[]);
    let out = ops::rename(
        &mut f.vault,
        RenameInput {
            canvas_id: c.clone(),
            title: "Board Two".into(),
            expected_version: 1,
        },
        &FixedClock(T1),
        None,
    )
    .unwrap();
    assert_eq!(out.canvas_id, c);
    assert_eq!(out.title, "Board Two");
    assert_eq!(out.version, 2);
    assert_eq!(out.updated_at, T1);
    assert_eq!(out.vault_id, f.vault.vault_id());
    assert_eq!(f.detail(&c).canvas.title, "Board Two");
    assert_eq!(
        keys(&serde_json::to_value(&out).unwrap()),
        ["canvas_id", "title", "updated_at", "vault_id", "version"]
    );
}

#[test]
fn ops_canvas_rename_with_a_stale_version_is_version_conflict() {
    let mut f = Fx::new();
    let c = f.canvas("Board", &[]);
    let err = ops::rename(
        &mut f.vault,
        RenameInput {
            canvas_id: c.clone(),
            title: "Board Two".into(),
            expected_version: 9,
        },
        &SystemClock,
        None,
    )
    .unwrap_err();
    let got = cli::error_json(&err);
    assert_eq!(got["error"]["code"], "version_conflict", "{got}");
    assert_eq!(f.detail(&c).canvas.title, "Board");
}

#[test]
fn ops_canvas_rm_deletes_the_canvas_and_returns_its_id() {
    let mut f = Fx::new();
    let a = f.note("Alpha", "a\n");
    let c = f.canvas("Board", &[&a]);
    let out = ops::rm(
        &mut f.vault,
        RmInput {
            canvas_id: c.clone(),
            expected_version: 2,
        },
        &SystemClock,
        None,
    )
    .unwrap();
    assert_eq!(out.canvas_id, c);
    assert_eq!(out.vault_id, f.vault.vault_id());
    assert!(core_canvas::list_canvases(&f.vault).unwrap().is_empty());
    assert!(
        notes::list_notes(&f.vault, 10).unwrap().len() == 1,
        "notes stay"
    );
    assert_eq!(
        serde_json::to_value(&out).unwrap(),
        json!({ "canvas_id": c, "vault_id": f.vault.vault_id() })
    );
}

#[test]
fn ops_canvas_rm_with_a_stale_version_is_version_conflict() {
    let mut f = Fx::new();
    let c = f.canvas("Board", &[]);
    let err = ops::rm(
        &mut f.vault,
        RmInput {
            canvas_id: c,
            expected_version: 5,
        },
        &SystemClock,
        None,
    )
    .unwrap_err();
    assert_eq!(cli::error_json(&err)["error"]["code"], "version_conflict");
    assert_eq!(core_canvas::list_canvases(&f.vault).unwrap().len(), 1);
}

// ---------- add / remove / move ----------

#[test]
fn ops_canvas_add_places_the_note_stamped_with_the_clock() {
    let mut f = Fx::new();
    let a = f.note("Alpha", "a\n");
    let c = f.canvas("Board", &[]);
    let out = ops::add(
        &mut f.vault,
        AddInput {
            canvas_id: c.clone(),
            note_id: a.clone(),
            x: 10.0,
            y: -2.5,
        },
        &FixedClock(T0),
        None,
    )
    .unwrap();
    assert_eq!(out.canvas_id, c);
    assert_eq!(out.note_id, a);
    assert_eq!(out.note_title, "Alpha");
    assert_eq!((out.x, out.y, out.z_order), (10.0, -2.5, 0));
    assert_eq!(out.placed_at, T0);
    assert_eq!(out.vault_id, f.vault.vault_id());
    let d = f.detail(&c);
    assert_eq!(d.canvas.updated_at, T0, "the canvas is stamped too");
    assert_eq!(d.nodes.len(), 1);
    assert_eq!(
        keys(&serde_json::to_value(&out).unwrap()),
        [
            "canvas_id",
            "note_id",
            "note_title",
            "placed_at",
            "vault_id",
            "x",
            "y",
            "z_order"
        ]
    );
}

#[test]
fn ops_canvas_add_of_an_unknown_note_maps_like_the_cli() {
    let mut f = Fx::new();
    let c = f.canvas("Board", &[]);
    for id in [ABSENT_ULID, "bad-id"] {
        let err = ops::add(
            &mut f.vault,
            AddInput {
                canvas_id: c.clone(),
                note_id: id.into(),
                ..Default::default()
            },
            &SystemClock,
            None,
        )
        .unwrap_err();
        assert_eq!(
            cli::error_json(&err),
            cli_err(&[
                "canvas",
                "add",
                "--vault",
                f.v(),
                "--canvas-id",
                &c,
                "--note-id",
                id
            ]),
            "{id}"
        );
    }
}

#[test]
fn ops_canvas_remove_drops_the_placement_and_returns_the_ids() {
    let mut f = Fx::new();
    let a = f.note("Alpha", "a\n");
    let b = f.note("Beta", "b\n");
    let c = f.canvas("Board", &[&a, &b]);
    let out = ops::remove(
        &mut f.vault,
        RemoveInput {
            canvas_id: c.clone(),
            note_id: b.clone(),
        },
        &FixedClock(T1),
        None,
    )
    .unwrap();
    assert_eq!(
        serde_json::to_value(&out).unwrap(),
        json!({ "canvas_id": c, "note_id": b, "vault_id": f.vault.vault_id() })
    );
    let d = f.detail(&c);
    assert_eq!(d.nodes.len(), 1);
    assert_eq!(d.nodes[0].note_id, a);
    assert_eq!(d.canvas.updated_at, T1);
}

#[test]
fn ops_canvas_move_sets_the_coordinates_and_z_stamped_with_the_clock() {
    let mut f = Fx::new();
    let a = f.note("Alpha", "a\n");
    let c = f.canvas("Board", &[&a]);
    let out = ops::move_node(
        &mut f.vault,
        MoveInput {
            canvas_id: c.clone(),
            note_id: a.clone(),
            x: 3.0,
            y: 4.0,
            z: Some(7),
        },
        &FixedClock(T1),
        None,
    )
    .unwrap();
    assert_eq!(out.canvas_id, c);
    assert_eq!(out.note_id, a);
    assert_eq!(out.note_title, "Alpha");
    assert_eq!((out.x, out.y, out.z_order), (3.0, 4.0, 7));
    assert_eq!(out.vault_id, f.vault.vault_id());
    assert_eq!(f.detail(&c).canvas.updated_at, T1);
    assert_eq!(
        keys(&serde_json::to_value(&out).unwrap()),
        [
            "canvas_id",
            "note_id",
            "note_title",
            "vault_id",
            "x",
            "y",
            "z_order"
        ]
    );

    // No z keeps the z-order.
    let out = ops::move_node(
        &mut f.vault,
        MoveInput {
            canvas_id: c.clone(),
            note_id: a.clone(),
            x: -1.0,
            y: 0.5,
            z: None,
        },
        &SystemClock,
        None,
    )
    .unwrap();
    assert_eq!((out.x, out.y, out.z_order), (-1.0, 0.5, 7));
}

#[test]
fn ops_canvas_move_of_an_unplaced_note_is_not_found() {
    let mut f = Fx::new();
    let a = f.note("Alpha", "a\n");
    let c = f.canvas("Board", &[]);
    let err = ops::move_node(
        &mut f.vault,
        MoveInput {
            canvas_id: c.clone(),
            note_id: a.clone(),
            x: 1.0,
            y: 1.0,
            z: None,
        },
        &SystemClock,
        None,
    )
    .unwrap_err();
    let got = cli::error_json(&err);
    assert_eq!(got["error"]["code"], "not_found", "{got}");
    assert_eq!(
        got,
        cli_err(&[
            "canvas",
            "move",
            "--vault",
            f.v(),
            "--canvas-id",
            &c,
            "--note-id",
            &a,
            "--x",
            "1",
            "--y",
            "1"
        ])
    );
}
