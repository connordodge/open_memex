//! Canvas ops: `memex canvas new|ls|get|rename|rm|add|remove|move`.
//!
//! Output fields are declared in the order `memex canvas` prints them.

use memex_core::embedder::Embedder;
use memex_core::{Clock, Vault};
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
    let _ = (vault, input, clock, embedder);
    anyhow::bail!("ops::canvas::new is not implemented yet (#73)")
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
    let _ = (vault, input, clock, embedder);
    anyhow::bail!("ops::canvas::ls is not implemented yet (#73)")
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
    let _ = (vault, input, clock, embedder);
    anyhow::bail!("ops::canvas::get is not implemented yet (#73)")
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
    let _ = (vault, input, clock, embedder);
    anyhow::bail!("ops::canvas::rename is not implemented yet (#73)")
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
    let _ = (vault, input, clock, embedder);
    anyhow::bail!("ops::canvas::rm is not implemented yet (#73)")
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
    let _ = (vault, input, clock, embedder);
    anyhow::bail!("ops::canvas::add is not implemented yet (#73)")
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
    let _ = (vault, input, clock, embedder);
    anyhow::bail!("ops::canvas::remove is not implemented yet (#73)")
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
    let _ = (vault, input, clock, embedder);
    anyhow::bail!("ops::canvas::move_node is not implemented yet (#73)")
}
