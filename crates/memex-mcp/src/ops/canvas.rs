//! Canvas ops: `memex canvas new|ls|get|rename|rm|add|remove|move`.
//!
//! Output fields are declared in the order `memex canvas` prints them.

use memex_core::canvas as core_canvas;
use memex_core::embedder::Embedder;
use memex_core::{CanvasId, Clock, NoteId, Vault};
use serde::Serialize;

/// The input of [`new`].
#[derive(Debug, Clone, Default)]
pub struct NewInput {
    pub title: String,
}

/// The `memex canvas new` output line.
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct NewOutput {
    pub canvas_id: String,
    pub created_at: i64,
    pub title: String,
    pub updated_at: i64,
    pub vault_id: String,
    pub version: i64,
}

/// Creates a canvas, stamped with the clock.
pub fn new(
    vault: &mut Vault,
    input: NewInput,
    clock: &dyn Clock,
    embedder: Option<&dyn Embedder>,
) -> anyhow::Result<NewOutput> {
    let _ = embedder;
    let c = core_canvas::create_canvas_with_clock(vault, input.title, clock)?;
    Ok(NewOutput {
        canvas_id: c.id.to_string(),
        created_at: c.created_at,
        title: c.title,
        updated_at: c.updated_at,
        vault_id: vault.vault_id().to_string(),
        version: c.version,
    })
}

/// The input of [`ls`].
#[derive(Debug, Clone, Default)]
pub struct LsInput;

/// One row of `memex canvas ls`.
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct CanvasRow {
    pub canvas_id: String,
    pub created_at: i64,
    pub node_count: i64,
    pub title: String,
    pub updated_at: i64,
    pub version: i64,
}

/// The `memex canvas ls` output line.
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct LsOutput {
    pub canvases: Vec<CanvasRow>,
    pub vault_id: String,
}

/// Lists every canvas.
pub fn ls(
    vault: &mut Vault,
    input: LsInput,
    clock: &dyn Clock,
    embedder: Option<&dyn Embedder>,
) -> anyhow::Result<LsOutput> {
    let _ = (input, clock, embedder);
    let canvases = core_canvas::list_canvases(vault)?
        .into_iter()
        .map(|s| CanvasRow {
            canvas_id: s.id.to_string(),
            created_at: s.created_at,
            node_count: s.node_count,
            title: s.title,
            updated_at: s.updated_at,
            version: s.version,
        })
        .collect();
    Ok(LsOutput {
        canvases,
        vault_id: vault.vault_id().to_string(),
    })
}

/// The input of [`get`].
#[derive(Debug, Clone, Default)]
pub struct GetInput {
    pub canvas_id: String,
}

/// A placed note in `memex canvas get`.
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct NodeOut {
    pub note_id: String,
    pub note_title: String,
    pub placed_at: i64,
    pub x: f64,
    pub y: f64,
    pub z_order: i64,
}

/// An edge in `memex canvas get`.
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct EdgeOut {
    pub from_note_id: String,
    pub kind: String,
    pub label: Option<String>,
    pub link_id: String,
    pub link_text: String,
    pub position: i64,
    pub source: String,
    pub to_note_id: String,
}

/// The `memex canvas get` output line.
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct GetOutput {
    pub canvas_id: String,
    pub created_at: i64,
    pub edges: Vec<EdgeOut>,
    pub nodes: Vec<NodeOut>,
    pub title: String,
    pub updated_at: i64,
    pub vault_id: String,
    pub version: i64,
}

/// Reads one canvas with its nodes and edges.
pub fn get(
    vault: &mut Vault,
    input: GetInput,
    clock: &dyn Clock,
    embedder: Option<&dyn Embedder>,
) -> anyhow::Result<GetOutput> {
    let _ = (clock, embedder);
    let cid = CanvasId::parse(&input.canvas_id)?;
    let d = core_canvas::get_canvas(vault, &cid)?;
    let nodes = d
        .nodes
        .into_iter()
        .map(|n| NodeOut {
            note_id: n.note_id,
            note_title: n.note_title,
            placed_at: n.placed_at,
            x: n.x,
            y: n.y,
            z_order: n.z_order,
        })
        .collect();
    let edges = d
        .edges
        .into_iter()
        .map(|e| EdgeOut {
            from_note_id: e.from_note_id,
            kind: e.link_kind.as_str().to_string(),
            label: e.label,
            link_id: e.link_id,
            link_text: e.link_text,
            position: e.position,
            source: e.source.as_str().to_string(),
            to_note_id: e.to_note_id,
        })
        .collect();
    Ok(GetOutput {
        canvas_id: d.canvas.id.to_string(),
        created_at: d.canvas.created_at,
        edges,
        nodes,
        title: d.canvas.title,
        updated_at: d.canvas.updated_at,
        vault_id: vault.vault_id().to_string(),
        version: d.canvas.version,
    })
}

/// The input of [`rename`].
#[derive(Debug, Clone, Default)]
pub struct RenameInput {
    pub canvas_id: String,
    pub title: String,
    pub expected_version: i64,
}

/// The `memex canvas rename` output line.
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct RenameOutput {
    pub canvas_id: String,
    pub title: String,
    pub updated_at: i64,
    pub vault_id: String,
    pub version: i64,
}

/// Renames a canvas, stamped with the clock.
pub fn rename(
    vault: &mut Vault,
    input: RenameInput,
    clock: &dyn Clock,
    embedder: Option<&dyn Embedder>,
) -> anyhow::Result<RenameOutput> {
    let _ = embedder;
    let cid = CanvasId::parse(&input.canvas_id)?;
    let c = core_canvas::rename_canvas_with_clock(
        vault,
        &cid,
        input.title,
        input.expected_version,
        clock,
    )?;
    Ok(RenameOutput {
        canvas_id: c.id.to_string(),
        title: c.title,
        updated_at: c.updated_at,
        vault_id: vault.vault_id().to_string(),
        version: c.version,
    })
}

/// The input of [`rm`].
#[derive(Debug, Clone, Default)]
pub struct RmInput {
    pub canvas_id: String,
    pub expected_version: i64,
}

/// The `memex canvas rm` output line.
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct RmOutput {
    pub canvas_id: String,
    pub vault_id: String,
}

/// Deletes a canvas (its placements cascade).
pub fn rm(
    vault: &mut Vault,
    input: RmInput,
    clock: &dyn Clock,
    embedder: Option<&dyn Embedder>,
) -> anyhow::Result<RmOutput> {
    let _ = (clock, embedder);
    let cid = CanvasId::parse(&input.canvas_id)?;
    core_canvas::delete_canvas(vault, &cid, input.expected_version)?;
    Ok(RmOutput {
        canvas_id: input.canvas_id,
        vault_id: vault.vault_id().to_string(),
    })
}

/// The input of [`add`].
#[derive(Debug, Clone, Default)]
pub struct AddInput {
    pub canvas_id: String,
    pub note_id: String,
    pub x: f64,
    pub y: f64,
}

/// The `memex canvas add` output line.
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct AddOutput {
    pub canvas_id: String,
    pub note_id: String,
    pub note_title: String,
    pub placed_at: i64,
    pub vault_id: String,
    pub x: f64,
    pub y: f64,
    pub z_order: i64,
}

/// Places a note on a canvas (idempotent), stamped with the clock.
pub fn add(
    vault: &mut Vault,
    input: AddInput,
    clock: &dyn Clock,
    embedder: Option<&dyn Embedder>,
) -> anyhow::Result<AddOutput> {
    let _ = embedder;
    let cid = CanvasId::parse(&input.canvas_id)?;
    NoteId::parse(&input.note_id)?;
    let node = core_canvas::add_to_canvas_with_clock(
        vault,
        &cid,
        &input.note_id,
        input.x,
        input.y,
        clock,
    )?;
    Ok(AddOutput {
        canvas_id: node.canvas_id.to_string(),
        note_id: node.note_id,
        note_title: node.note_title,
        placed_at: node.placed_at,
        vault_id: vault.vault_id().to_string(),
        x: node.x,
        y: node.y,
        z_order: node.z_order,
    })
}

/// The input of [`remove`].
#[derive(Debug, Clone, Default)]
pub struct RemoveInput {
    pub canvas_id: String,
    pub note_id: String,
}

/// The `memex canvas remove` output line.
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct RemoveOutput {
    pub canvas_id: String,
    pub note_id: String,
    pub vault_id: String,
}

/// Removes a note's placement from a canvas, stamped with the clock.
pub fn remove(
    vault: &mut Vault,
    input: RemoveInput,
    clock: &dyn Clock,
    embedder: Option<&dyn Embedder>,
) -> anyhow::Result<RemoveOutput> {
    let _ = embedder;
    let cid = CanvasId::parse(&input.canvas_id)?;
    core_canvas::remove_from_canvas_with_clock(vault, &cid, &input.note_id, clock)?;
    Ok(RemoveOutput {
        canvas_id: input.canvas_id,
        note_id: input.note_id,
        vault_id: vault.vault_id().to_string(),
    })
}

/// The input of [`move_node`] (`memex canvas move`).
#[derive(Debug, Clone, Default)]
pub struct MoveInput {
    pub canvas_id: String,
    pub note_id: String,
    pub x: f64,
    pub y: f64,
    /// The new z-order; `None` keeps it.
    pub z: Option<i64>,
}

/// The `memex canvas move` output line.
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct MoveOutput {
    pub canvas_id: String,
    pub note_id: String,
    pub note_title: String,
    pub vault_id: String,
    pub x: f64,
    pub y: f64,
    pub z_order: i64,
}

/// Moves a placed note, stamped with the clock.
pub fn move_node(
    vault: &mut Vault,
    input: MoveInput,
    clock: &dyn Clock,
    embedder: Option<&dyn Embedder>,
) -> anyhow::Result<MoveOutput> {
    let _ = embedder;
    let cid = CanvasId::parse(&input.canvas_id)?;
    let node = core_canvas::move_node_with_clock(
        vault,
        &cid,
        &input.note_id,
        input.x,
        input.y,
        input.z,
        clock,
    )?;
    Ok(MoveOutput {
        canvas_id: node.canvas_id.to_string(),
        note_id: node.note_id,
        note_title: node.note_title,
        vault_id: vault.vault_id().to_string(),
        x: node.x,
        y: node.y,
        z_order: node.z_order,
    })
}
