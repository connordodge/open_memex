<goal>
Add a visual **canvas view** to Open Memex so users can spatially organize notes and see how they connect. Each canvas is a user-curated board: notes placed onto it become draggable nodes, and the existing typed wikilinks between any two placed notes render as labelled lines.

Canvases are first-class entities — stored in the vault DB, exposed through the CLI, surfaced in the Flutter macOS app as a tabbed workspace, and reachable through MCP so AI agents can read and curate them too.

Concretely:

- "Concepts" = existing notes. Placing a concept on a canvas is a (canvas, note, x, y) record.
- "Lines" = existing wikilinks. Drawing a line from node A to node B inserts a `[[B~kind|label?]]` wikilink into A's body via the existing wikilink path; the line's `kind` and `label` are the wikilink's `link_kind` and `label`.
- Wikilinks whose source or target is **not** placed on the active canvas do not render.

Who benefits:

- A solo user thinking through a domain visually — drag related notes near each other, draw typed lines, see the picture.
- Claude / MCP agents — can build and query canvases (e.g. "assemble a canvas of every note that contradicts X").

This is purely additive UX over the existing note + wikilink model; the canvas layer never owns content, only placement.
</goal>

<background>
Repo is a Rust workspace + Flutter macOS app (macOS-only for now).

- `crates/memex-core/` — SQLite-backed vault (`memex.db`, WAL mode, FTS5, optional `vec0`). Schema migrations live in `src/schema.rs` with a monotonic `APP_SCHEMA_VERSION` (currently `3`). Wikilinks live in the `links` table — `(from_note_id, to_note_id, link_text, link_kind, label, position, source)` — and rename rewrites are transactional.
- `crates/memex-mcp/` — single `memex` binary that is both the CLI and the MCP server. Existing MCP tools: `search`, `get_note`, `create_note`, `neighbors`, `add_link`. Tool wiring is in `crates/memex-mcp/src/tools.rs` using `rmcp` attribute macros.
- `app/` — Flutter desktop app. Riverpod for state. Today's shell is a three-pane `Row`: `Sidebar | NoteEditor | RightPanel`. The Flutter app calls into the `memex` binary as a subprocess for writes and reads SQLite directly via `sqlite3` for reads.

Files to examine before implementing:

- `@crates/memex-core/src/schema.rs` — how migrations are layered (V1, V2, V3, `apply()`); new schema must go in `V4` with `APP_SCHEMA_VERSION = 4`.
- `@crates/memex-core/src/notes.rs`, `@crates/memex-core/src/links.rs`, `@crates/memex-core/src/graph.rs` — patterns for CRUD + the optimistic-concurrency `expected_version` pattern.
- `@crates/memex-core/src/link_extractor.rs` and the `add_link` flow in `@crates/memex-mcp/src/tools.rs` — the canonical "insert a wikilink into a note's body" path that canvas line-creation must reuse, not reimplement.
- `@crates/memex-mcp/src/tools.rs` and `@crates/memex-mcp/src/main.rs` — pattern for adding CLI subcommands and MCP tools.
- `@app/lib/src/screens/main_window.dart`, `@app/lib/src/widgets/sidebar.dart`, `@app/lib/src/widgets/note_editor.dart`, `@app/lib/src/widgets/right_panel.dart` — current shell; new shell replaces `MainWindow`'s single-tab layout with a tabbed workspace.
- `@app/lib/src/state/vault_state.dart` — Riverpod provider patterns to mirror for canvas/tab state.
- `@docs/wikilinks.md` — the user-facing contract for wikilinks; canvas lines must obey it.

Out of scope for this spec (deferred):

- Multi-window canvases.
- Ad-hoc "sticky" concepts that aren't backed by a note.
- Force-directed or any auto-layout. v1 is manual positions only.
- Rendering wikilinks to off-canvas notes as ghost nodes (Q2 chose "hide entirely").
- Mobile / Windows / Linux (Flutter app stays macOS-only).
- Transclusion-on-canvas (`![[Title]]`).
- CRDT/sync for canvas positions across devices (single-device only, like the rest of the app today).
</background>

<user_flows>
**Primary flow — build a canvas:**

1. User opens an existing vault. Workspace shell shows two-list left rail (canvases on top, notes below) and an empty tab bar.
2. User clicks "+ New canvas" in the canvases section, types "Research Q2", presses Enter. A new canvas row appears in the rail and opens as a new tab.
3. User drags Note A from the notes section of the rail onto the canvas. A node appears at the drop point.
4. User drags Note B onto the canvas; positions it to the right of A.
5. User hovers over node A. An edge-handle pip appears on its border. User drags from the pip toward node B; a live ghost line follows the cursor.
6. On drop over node B, a popover anchored at the drop point asks for `kind` (chips: `references`, `extends`, `contradicts`, `example-of`, `More…`) and an optional label. User picks `extends`, types "builds on local-first idea", confirms.
7. A solid line appears from A to B with the label rendered beside it. Under the hood, `[[B~extends|builds on local-first idea]]` is inserted into A's body via the existing `add_link` path.
8. User double-clicks node B. The canvas zooms into B's note view inside the same tab with an animated transition (~250ms). A back arrow appears in the tab's top-left.
9. User edits B's body in the note editor; debounced save runs through the existing path.
10. User clicks the back arrow. The view animates back to the canvas at the same zoom and pan as before; B's node still selected.

**Alternative flow — AI-curated canvas:**

1. Claude (via MCP) calls `create_canvas(title: "Open Questions")`, then `add_to_canvas` for each note matching some query, with synthesized positions.
2. User opens the app later. "Open Questions" appears in the canvases rail. Clicking it opens a populated tab.
3. User refines manually — drags nodes, draws new lines.

**Alternative flow — already-open tab:**

1. User clicks a canvas or note in the rail that's already open in a tab. Workspace switches to that tab instead of creating a new one.

**Error / recovery flows:**

- **Self-link via drag:** User drags from node A's edge-handle back onto node A. Drop is rejected; brief inline toast: "Can't link a note to itself." No write occurs.
- **Drop a note that's already on the canvas:** Drag from rail of an already-placed note is rejected at the canvas's `onWillAccept`; node briefly pulses to indicate "it's already here."
- **Wikilink-insert failure** (e.g., source note's body has a syntax error preventing the extractor from running): popover stays open with an error banner; no line is rendered until the user dismisses or retries.
- **Note renamed while canvas open:** Existing transactional rename pass rewrites wikilinks in linker bodies. Canvas re-renders the line with the new title; node label updates from the canvas's cached `note_title` (must refresh on a `notes` change broadcast).
- **Note deleted while placed on canvases:** FK `ON DELETE CASCADE` on `canvas_nodes(note_id)` removes the placement. Open canvas tabs receive a refresh signal and re-render without the node and any lines that touched it.
- **Canvas deleted while open in a tab:** Tab closes. If the user invoked delete from the rail, confirm with a dialog ("Delete canvas 'Research Q2'? Notes will not be affected."). Pending position drags are auto-committed before delete so nothing is mid-flight.

**Edge cases:**

- **Multiple wikilinks between same pair of nodes** (e.g., A `extends` B *and* A `references` B): render as two slightly offset parallel curves, each independently selectable and labelled.
- **Bidirectional pair** (A → B and B → A): render as two opposing arrows, not collapsed into one.
- **Ghost wikilink** (A's body has `[[Nonexistent]]`): no line, since the target isn't a placed node — and isn't a note at all. No-op for the canvas.
- **Concurrent drag of multiple nodes** (marquee selection + drag): single transactional position update across all moved nodes.
- **Pan/zoom while dragging an edge:** the in-flight line follows the pointer in canvas coordinates, not screen coordinates.
- **Closing the last tab:** workspace shows an empty placeholder ("Open a canvas or note from the left to get started"). The rail stays.
</user_flows>

<requirements>
**Functional — data model (memex-core):**

1. Add SQLite migration **V4** (bump `APP_SCHEMA_VERSION` to `4`) creating:
   - `canvases (id TEXT PRIMARY KEY, title TEXT NOT NULL, created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL, version INTEGER NOT NULL DEFAULT 1)` with `UNIQUE(title)`.
   - `canvas_nodes (canvas_id TEXT NOT NULL REFERENCES canvases(id) ON DELETE CASCADE, note_id TEXT NOT NULL REFERENCES notes(id) ON DELETE CASCADE, x REAL NOT NULL, y REAL NOT NULL, z_order INTEGER NOT NULL DEFAULT 0, placed_at INTEGER NOT NULL, PRIMARY KEY (canvas_id, note_id))`.
   - Index `idx_canvas_nodes_note ON canvas_nodes(note_id)` so a note-deleted cascade is efficient and `get_canvas` lookups by node are fast.
2. Add `crates/memex-core/src/canvas.rs` exposing `Canvas`, `CanvasNode`, and `CanvasEdge` types and these functions:
   - `create_canvas(vault, title) -> Canvas` — fails with `TitleConflict` on duplicate title.
   - `list_canvases(vault) -> Vec<CanvasSummary>` — ordered by `updated_at DESC`; includes `node_count`.
   - `get_canvas(vault, id) -> CanvasDetail` — returns canvas + `Vec<CanvasNode>` (each with note_id, note_title, x, y, z_order) + `Vec<CanvasEdge>` (each row in `links` whose `from_note_id` AND `to_note_id` are both placed on this canvas, including kind/label/source/position).
   - `rename_canvas(vault, id, new_title, expected_version) -> Canvas` — optimistic concurrency, same pattern as `notes::update_note`.
   - `delete_canvas(vault, id, expected_version) -> ()` — cascades placements only; never touches notes or links.
   - `add_to_canvas(vault, canvas_id, note_id, x, y) -> CanvasNode` — idempotent on `(canvas_id, note_id)`: returns existing row if present, position unchanged.
   - `remove_from_canvas(vault, canvas_id, note_id) -> ()` — no-op if absent.
   - `move_node(vault, canvas_id, note_id, x, y, z_order?) -> CanvasNode` — single-row update; bumps `canvases.updated_at`.
   - `move_nodes_batch(vault, canvas_id, &[(note_id, x, y)]) -> Vec<CanvasNode>` — single transaction; for marquee drag.
3. `get_canvas` must use the existing `links` query infrastructure rather than a parallel "canvas links" table — the canvas layer never owns edges.
4. All canvas writes bump `canvases.updated_at` for the affected canvas and use the same `expected_version` optimistic-concurrency error type as note writes.

**Functional — CLI (memex-mcp):**

5. Add subcommands mirroring core API:
   - `memex canvas new --vault <p> --title <t>`
   - `memex canvas ls --vault <p>`
   - `memex canvas get --vault <p> --canvas-id <id>` (JSON output matching `get_canvas`)
   - `memex canvas rename --vault <p> --canvas-id <id> --title <t> --expected-version <v>`
   - `memex canvas rm --vault <p> --canvas-id <id> --expected-version <v>`
   - `memex canvas add --vault <p> --canvas-id <id> --note-id <id> --x <f> --y <f>`
   - `memex canvas remove --vault <p> --canvas-id <id> --note-id <id>`
   - `memex canvas move --vault <p> --canvas-id <id> --note-id <id> --x <f> --y <f> [--z <i>]`

**Functional — MCP tools (memex-mcp):**

6. Add 7 new MCP tools wired in `crates/memex-mcp/src/tools.rs`, following the existing `rmcp` `#[tool]` attribute pattern:
   - `list_canvases()` — read-only summary list.
   - `get_canvas(canvas_id)` — full detail with nodes + edges. Edges include the same fields as `get_note(include_links)` returns for the `links` map (kind, label, target id+title, source).
   - `create_canvas(title)`.
   - `add_to_canvas(canvas_id, note_id, x?, y?)` — `x`/`y` default to `0.0`/`0.0`; let the UI compute positions and write them back if it cares.
   - `remove_from_canvas(canvas_id, note_id)`.
   - `move_node(canvas_id, note_id, x, y, z_order?)`.
   - `delete_canvas(canvas_id, expected_version)`.
7. The existing `add_link` MCP tool **does not change**. Canvas line-creation in the Flutter app calls into the same in-process wikilink-insert path; no new MCP tool for "create a canvas edge" because edges aren't a canvas concept.

**Functional — Flutter shell:**

8. Replace `MainWindow` with a `Workspace` widget that renders:
   - Two-list left rail (`CanvasesRail` above, `NotesRail` below) with independent search inputs and "+ New" affordances. Both lists virtualized for large vaults.
   - A `TabBar` across the top of the right region with closeable tabs. Each tab is either `CanvasTab(canvasId)` or `NoteTab(noteId)`.
   - A `TabBody` that renders the active tab's content. For `NoteTab`, reuse the existing `NoteEditor` + `RightPanel` layout. For `CanvasTab`, render the new `CanvasView`.
9. Clicking a row in either rail:
   - If a tab for that id already exists → switch active tab to it.
   - Else → append a new tab and activate it.
10. Tabs are closeable via an "x" button or middle-click; closing the active tab activates the previous tab. Closing the last tab shows an empty-state placeholder.
11. Tab state (open tabs, active tab, per-canvas pan/zoom state) persists per-vault to the same on-disk state file used by `recentVaultsProvider` / `currentVaultProvider` (extend, don't fork the file format).

**Functional — Canvas view:**

12. `CanvasView` uses `InteractiveViewer` for pan + zoom (min 0.1×, max 4×, default 1×). Pinch / `Cmd+scroll` zooms; two-finger pan or middle-drag pans.
13. Nodes are `Positioned` children of a `Stack` inside the `InteractiveViewer`. Each node renders the note's title, a small kind chip indicating outbound link kinds at a glance (if any), and a hover-revealed edge-handle pip on its border.
14. Edges between two placed nodes render via a single `CustomPaint` over the node layer, drawing one cubic Bézier per `links` row whose endpoints are both placed on the canvas. Multiple links between the same pair get parallel offsets. Each edge carries a hit-test region for click selection.
15. Lines that have a `label` render the label as a small pill anchored at the curve's midpoint with a leader to the curve. Lines without a label render their `kind` as a small chip instead (unless `kind = references`, which renders no chip to keep the canvas clean).
16. Dragging a node updates its (x, y) locally at 60fps and debounces a persistence write (200ms) via `move_node`. Marquee-selection multi-drag uses `move_nodes_batch`.
17. **Drag from rail onto canvas:** the rail's note row is a `Draggable<NoteId>`; the canvas is a `DragTarget<NoteId>` that converts pointer position to canvas coordinates, then calls `add_to_canvas`. If the note is already placed, the target's `onWillAccept` rejects and the placed node pulses.
18. **Drag-to-link:** when hovering a node, an edge-handle pip is rendered on the side of the node nearest the pointer. Pressing on the pip starts an "edge gesture" — a live ghost line follows the cursor. On pointer-up:
    - If over another placed node and that node isn't the source: open a popover anchored at drop point with kind chips (built-ins + a "More…" picker that surfaces previously used user-defined kinds) and an optional label `TextField`. Confirm → call the existing wikilink-insert path (via the `memex` CLI subprocess, same pattern as today's `add_link` from the app). On success, refresh edges.
    - Else (over empty canvas, or over the source node, or off-canvas): cancel; no write.
19. **Edge inspector:** clicking an edge opens an inline floating inspector with the edge's `kind` (editable) and `label` (editable). Saving rewrites the wikilink in the source note's body via the same path the autocomplete kind-chip uses today (`memex update --note-id ...` or a more targeted edge update — see Implementation Notes).
20. **Double-click a node:** triggers an animated zoom-in transition into the note's full editor inside the same tab. The tab's title updates to the note's title prefixed with the canvas name as a back-reference ("← Research Q2 / Note B"). A back arrow in the top-left animates back to the canvas at the previously-saved pan/zoom. Animation duration ~250ms, curve `Curves.easeInOut`. Use Flutter `Hero` for the node-to-editor transition where feasible; fall back to `AnimatedSwitcher` + `Transform` if `Hero` is incompatible with `InteractiveViewer`'s coordinate space.

**Error Handling:**

21. **Self-link drop** (pointer-up over source): silent reject, brief `SnackBar` "Can't link a note to itself."
22. **Drop already-placed note onto canvas:** silent reject; the existing placed node pulses (200ms scale animation) to draw the eye.
23. **CLI subprocess failure during line creation:** popover shows error banner with retry; no line until success; canvas state is not touched.
24. **Concurrent modification** (another writer bumped `canvases.version`): show error toast "Canvas was modified elsewhere — refresh"; refresh the canvas tab.
25. **Note rename / delete during canvas open:** subscribe to the same `vaultRevisionProvider` (or a new `canvasRevisionProvider` per canvas) bump signal already used by the sidebar to refetch on changes.
26. **Migration safety:** V4 migration runs in its own transaction; if it fails partway, the migration rolls back and the app refuses to open the vault with a clear "schema migration failed" error referencing the existing migration triage screen.

**Edge Cases:**

27. **Title conflict on canvas create/rename:** core returns `TitleConflict`; app shows inline error in the rename input. CLI returns non-zero exit + error JSON on stderr.
28. **Empty canvas:** placeholder text in the canvas viewport — "Drag a note from the left to get started."
29. **Many nodes (≥200):** edge `CustomPaint` should remain at 60fps. Spec target: 500 placed nodes + 1000 edges on M-series Macs. Beyond that, no defined behavior in v1.
30. **Off-canvas wikilinks** (per Q2): hidden entirely. No badges, no stubs. The right-panel Connections tab on a note still shows them when the user zooms in.
31. **Bidirectional and multi-kind pairs:** rendered as multiple offset curves, each independently clickable; never collapsed.
32. **Position values:** `f64` in core, stored as SQLite `REAL`. No clamping; canvas is mathematically unbounded. Pan/zoom UI handles the practical bounds.
33. **z_order:** v1 uses ascending insertion order for placement (newer placements render on top during drag); explicit `z_order` reorders on user "Bring to front" / "Send to back" right-click action. Optional in v1; if not implemented, document as deferred.
34. **Tab persistence vs. data loss:** position drags are auto-saved; tab list is auto-saved. No "unsaved canvas" prompt is needed.

**Validation:**

35. Every public function in `canvas.rs` has unit tests covering happy path, error path, and at least one edge case.
36. MCP tools have integration tests that round-trip JSON-RPC against the in-process tool router.
37. Flutter widget tests cover canvas rendering, drag-to-link gesture, drag-from-rail gesture, edge inspector edit, animated zoom in/out, and tab switching.
38. At least one robot-driven journey test exercises the **primary flow** end-to-end against a real `memex` binary + vault.
</requirements>

<boundaries>
**Edge cases:**

- **Self-link drop:** silent reject, no write.
- **Already-placed drop:** silent reject, node pulses.
- **Multiple lines between same pair:** parallel offset curves; never merged.
- **Bidirectional pair:** rendered as two arrows.
- **Ghost wikilink target:** no line rendered (target isn't a note).
- **Note rename:** existing transactional rewrite of wikilinks fires; canvas refreshes labels.
- **Note delete:** FK cascade removes placements; canvas refreshes.
- **Canvas delete with confirm:** dialog before delete; cancels are safe.
- **Title conflict:** rejected by `UNIQUE(canvases.title)` constraint with `TitleConflict` error surfaced inline.

**Error scenarios:**

- **`memex` subprocess error during line creation:** popover shows banner with retry; canvas not mutated; user can dismiss to abandon.
- **SQLite busy / WAL contention:** retry with exponential backoff up to 3 attempts (mirror existing pattern in `notes.rs`).
- **Schema migration V4 failure:** rollback, refuse to open vault, surface in migration triage screen with the existing copy ("schema migration failed; restore from backup").
- **MCP tool input validation:** invalid `note_id`, missing canvas, non-finite x/y → return structured error payload via `err_payload()` helper used by existing tools.

**Limits:**

- **Performance target:** 500 nodes + 1000 edges at 60fps pan/zoom on M-series Macs. Above this, no v1 guarantee — document in `docs/canvas.md`.
- **Title length:** same as note titles (255 chars).
- **Position values:** `f64`, no bounds. UI's `InteractiveViewer` enforces practical zoom bounds [0.1×, 4×].
- **Canvas count per vault:** no hard limit; rail list is virtualized.
- **Tab count:** soft cap of 20 open tabs; opening the 21st closes the oldest non-active tab. (Open question: confirm with user or just LRU silently — default to silent LRU.)
</boundaries>

<implementation>
**Files to create:**

- `crates/memex-core/src/canvas.rs` — types + CRUD functions. Mirrors the structure of `crates/memex-core/src/notes.rs`.
- `app/lib/src/screens/workspace.dart` — new top-level shell, replaces `main_window.dart` as the routed widget (keep `main_window.dart` momentarily for diff readability, delete in the final phase).
- `app/lib/src/widgets/canvas_view.dart` — main canvas widget (InteractiveViewer + Stack + CustomPaint).
- `app/lib/src/widgets/canvas_node.dart` — single-node widget with hover edge-handle.
- `app/lib/src/widgets/canvas_edge_painter.dart` — `CustomPainter` for edges + hit-test.
- `app/lib/src/widgets/canvas_edge_inspector.dart` — floating panel for editing a selected edge.
- `app/lib/src/widgets/edge_creation_overlay.dart` — drives the drag-to-link gesture, owns the ghost-line layer and drop-popover.
- `app/lib/src/widgets/canvases_rail.dart`, `app/lib/src/widgets/notes_rail.dart` — replace today's monolithic `Sidebar` with two co-equal rail sections (or refactor `Sidebar` to host both).
- `app/lib/src/widgets/tab_bar_widget.dart`, `app/lib/src/widgets/tab_body.dart` — workspace tab strip + body.
- `app/lib/src/state/canvas_state.dart` — Riverpod providers: `canvasesProvider`, `canvasDetailProvider(canvasId)`, `tabsProvider`, `activeTabProvider`, `canvasViewportProvider(canvasId)` (pan/zoom).

**Files to modify:**

- `crates/memex-core/src/schema.rs` — add `V4_*` SQL constants; bump `APP_SCHEMA_VERSION = 4`; extend `apply()` with the V4 step in its own transaction.
- `crates/memex-core/src/lib.rs` — re-export `canvas` module's public types.
- `crates/memex-core/src/error.rs` — add any new `MemexError` variants if not already covered (e.g., `CanvasNotFound`; `TitleConflict` already exists for notes — reuse).
- `crates/memex-mcp/src/main.rs` — add `canvas` subcommand group.
- `crates/memex-mcp/src/tools.rs` — add 7 new `#[tool]` methods following the existing pattern (Parameters struct + handler + serialize result).
- `app/lib/main.dart` — route to `Workspace` instead of `MainWindow`.
- `app/lib/src/state/vault_state.dart` — extend persisted state file to include tabs (open ids + active index) per vault.
- `app/lib/src/memex_cli.dart` — add wrapper methods for the new CLI subcommands.
- `README.md` and `docs/wikilinks.md` — append a "Canvas" section pointing at a new `docs/canvas.md` (see below).

**New docs:**

- `docs/canvas.md` — user-facing reference. Cover: what canvases are, how to create/place/link, the line-as-wikilink contract, off-canvas hiding policy, MCP tool list, and current limits.

**Patterns to follow:**

- Optimistic concurrency: same `expected_version` style as `notes::update_note` for `rename_canvas` and `delete_canvas`. Position writes (`move_node`) bump `canvases.version` but accept any expected_version (positions are CRDT-ish in practice — last-write-wins is fine for single-device).
- Wikilink insertion: **do not duplicate** the body-mutation logic. The Flutter app must invoke the same path as the existing autocomplete kind-chip — today that calls `memex update --note-id ...` with a rewritten body. Either reuse that, or expose a narrower `memex add-link` shape if the existing one already covers it (it does: `memex add-link --vault --from --to --kind --label`). Prefer the latter — it's idempotent.
- Migration: each migration in `schema.rs` is its own transaction (see V1/V2/V3 pattern). V4 must do the same.
- MCP error payloads: use the existing `err_payload(scope, message)` helper.
- Flutter state: Riverpod providers; no `ChangeNotifier` direct usage; mirror `vaultRevisionProvider` for cross-tab refresh signaling.

**What to avoid and why:**

- **Don't create a `canvas_edges` table.** Lines are a view over the existing `links` table — duplicating them would let canvas state and wikilink state diverge, defeating the whole "concept = note, line = wikilink" decision.
- **Don't introduce force-directed layout.** v1 is manual positions only per Q4; force-directed work is deferred.
- **Don't render off-canvas link badges or ghost nodes.** Per Q2 the canvas hides them entirely.
- **Don't put canvas state in a separate file/format.** Use the same SQLite DB so MCP / CLI / app all share one source of truth.
- **Don't add a new MCP tool for "create canvas edge."** The existing `add_link` is the single path; the canvas UI calls it via the CLI subprocess.
- **Don't fork the existing on-disk app-state file format.** Extend it.

**Implementation notes / open considerations to resolve in plan:**

- **Edge edit performance:** If editing an edge requires a full `memex update` body rewrite, multi-edge edits may be slow. The plan phase should evaluate adding a narrower `memex update-link --link-id <id> [--kind <k>] [--label <l>]` CLI / MCP tool that rewrites just the matching wikilink occurrence in the source body — same transactional contract, but ergonomic for inspector edits. If added, this is the only new wikilink-write surface; the canvas still doesn't own edges.
- **Hero animation with InteractiveViewer:** Flutter's `Hero` flight crosses the navigator level; if the canvas-to-note transition stays within the same tab body, an `AnimatedSwitcher` + matrix-interpolated `Transform.scale` from the clicked node's bounds to fill is simpler and avoids `Hero` interaction with `InteractiveViewer`'s transform.
- **Tab persistence schema:** decide between extending the existing JSON state file with a `tabs` array per vault entry vs. a small SQLite table inside the vault. Prefer JSON file to keep vault DB ownership unambiguous (the vault DB is shared with MCP; tab UI state is per-machine, not per-vault).
</implementation>

<validation>
**Baseline automated coverage outcomes (required across all phases):**

- **Logic / business rules** (Rust unit tests under `crates/memex-core/src/canvas.rs` `#[cfg(test)] mod tests`): every public function, each happy path + at least one error path. `get_canvas` must be tested with: empty canvas, canvas with placed notes but no edges, canvas with edges between placed nodes, canvas with wikilinks to off-canvas notes (asserting those edges are excluded), canvas with multiple wikilinks between the same pair (asserting all are returned). Title uniqueness, FK cascade on note delete, FK cascade on canvas delete. `move_nodes_batch` is single-transaction (assert via deliberate mid-batch failure rolling back the whole batch).
- **MCP integration tests** (Rust): each new MCP tool round-trips through the tool router with valid + invalid inputs; error payloads match the `err_payload` shape used by existing tools. `get_canvas` JSON shape matches the documented schema in `docs/canvas.md`.
- **UI behavior — widget tests** (Flutter under `app/test/`): canvas renders nodes at correct positions; dragging a node updates position and debounces persistence; drag-from-rail places a node; edge-handle drag opens the kind popover; popover writes through `MemexCli.addLink`; edge inspector edits write back through `MemexCli`; double-click triggers animated zoom into editor; back arrow animates back; rail click switches/opens a tab; closing the last tab shows empty state.
- **Critical user journeys — robot tests** (Flutter under `app/test/journeys/`): one end-to-end robot test for the **Primary flow** (create canvas → place two notes → draw line with label → double-click to zoom in → edit body → zoom back out → assert line still rendered with label). Robot must use stable selectors (`Key('canvas-node-$noteId')`, `Key('edge-handle-$noteId')`, `Key('canvas-edge-$linkId')`, `Key('canvases-rail')`, `Key('notes-rail')`, `Key('tab-$tabId')`) and pump animations to completion before each assertion.

**TDD-first expectations** (for testable logic and widget behavior):

- Vertical-slice RED → GREEN → REFACTOR: write one failing test, write the minimum code to pass, refactor, then move to the next test. Per `act-flutter-tdd` guidance.
- Behavior ordering inside each module: happy path first → edge cases → error handling. Don't mock until a real boundary forces it.
- **Testability seams that must exist:**
  - `MemexCli` is already an injectable dependency in Flutter — canvas widgets must depend on it via the same Riverpod provider, not construct it directly, so tests can inject a fake.
  - A `CanvasController` (or `canvasDetailProvider`) abstracts canvas reads so widget tests can preload arbitrary canvas state.
  - The edge-creation popover takes its "insert link" callback as a parameter so the gesture layer can be tested without hitting the CLI.
  - `move_node` debounce duration is injectable for tests (default 200ms; tests inject 0).
- **Mocking policy:** prefer in-memory fakes (`InMemoryMemexCli`, `InMemoryVault`) over `mockito`-style mocks. Only true external boundaries (the `memex` subprocess in robot tests) may use process-real execution; everything else uses fakes.
- **Justified exception:** the animated zoom-in transition's exact pixel choreography is verified visually (screenshot test or manual run via `act-flutter-screenshot`), not by widget tests. Widget tests assert *that* the editor becomes visible after the animation completes and *that* the back arrow returns to the canvas — not the interpolation curve.

**Test-type split for user-facing flows:**

- **Robot (end-to-end):** the Primary flow listed above. Real `memex` binary, real SQLite vault under a tmp dir, real `MemexCli`.
- **Widget (screen-level):** edge cases at single-screen scope — self-link reject, already-placed reject, edge inspector edit + cancel, drag-from-rail rejected for non-existent vault, drag with intermittent CLI failure (popover error + retry), marquee multi-drag commits batched, tab close behavior, empty-state placeholder.
- **Unit (logic):** all `canvas.rs` functions, the JSON shape of `get_canvas`, the FK cascade behaviors, the kind/label round-trip through `add_link`, the migration V4 itself (open a V3-schema DB, run apply, assert V4 tables exist and prior data is untouched).

**Required stable selectors (Flutter `Key` values):**

- `Key('canvases-rail')`, `Key('notes-rail')`
- `Key('canvas-row-$canvasId')`, `Key('note-row-$noteId')`
- `Key('new-canvas-button')`, `Key('new-note-button')`
- `Key('workspace-tab-bar')`, `Key('tab-$tabId')`, `Key('tab-close-$tabId')`
- `Key('canvas-view-$canvasId')`, `Key('canvas-node-$noteId')`, `Key('edge-handle-$noteId')`
- `Key('canvas-edge-$linkId')`, `Key('edge-inspector')`, `Key('edge-kind-chip-$kind')`, `Key('edge-label-input')`
- `Key('link-popover')`, `Key('link-popover-confirm')`, `Key('link-popover-cancel')`
- `Key('zoom-in-target-$noteId')`, `Key('zoom-out-back-button')`

**Required deterministic test seams:**

- `canvasViewportProvider(canvasId)` overridable in tests to start at known pan/zoom.
- Animation durations injectable via a `canvasAnimationConfigProvider` — tests use `Duration.zero` and pump once.
- Debounce timers injectable for `move_node` (default 200ms; tests use 0).
- Clock injectable for `created_at` / `updated_at` writes in `canvas.rs` (use the existing clock pattern already in `notes.rs` if present; otherwise introduce a thin trait).
- `MemexCli` swappable for `InMemoryMemexCli` everywhere it's consumed.

**Manual verification (in addition to automated):**

- Run `cargo test --workspace` — all green.
- Run `cargo clippy --workspace --all-targets -- -D warnings` — clean.
- Run `cd app && flutter analyze && flutter test` — clean.
- Run the app: `flutter run -d macos`. Walk through the Primary flow once, confirming animation smoothness. Capture a screenshot via `act-flutter-screenshot` for the spec phase's done-check.
- Run `memex serve --vault ...` against a built MCP client (Claude Desktop or the inspector); confirm `list_canvases` / `get_canvas` / `create_canvas` round-trip.

**Known risks to report explicitly:**

- The animated zoom transition is the highest-risk piece — `InteractiveViewer`'s transform composes with `Hero` in non-obvious ways. If the agreed-on `AnimatedSwitcher` + matrix-interpolated `Transform` approach is too jittery in practice, the plan should flag a fallback to a non-animated cut.
- Edge hit-testing on cubic Béziers must be tolerant (~6px corridor) — if hit-testing is fragile in practice, escalate before finalizing the inspector UX.
- Performance target (500 nodes / 1000 edges) is an aspirational v1 cap, not an SLA. If pan/zoom degrades earlier in profiling, flag it.

**Test gaps to acknowledge:**

- No automated test for the actual visual animation smoothness — covered by manual verification + screenshots only.
- No automated test for multi-window (deferred entirely).
- No load test beyond the 500/1000 target — anything above is undefined.
</validation>

<done_when>
- [ ] V4 migration shipped; `APP_SCHEMA_VERSION = 4`; existing V3 vaults open without data loss.
- [ ] `crates/memex-core/src/canvas.rs` exists with the 9 functions in Requirement 2; unit tests cover happy + error + edge cases for each.
- [ ] `memex canvas …` CLI subcommands exist and round-trip JSON cleanly; covered by integration tests.
- [ ] 7 new MCP tools shipped; integration tests pass; existing 5 MCP tools unchanged.
- [ ] Flutter app's shell is replaced with the tabbed `Workspace`; two-list rail; clicking opens-or-switches tab.
- [ ] Canvas view supports: pan/zoom, drag-from-rail placement, drag-to-link with kind/label popover, edge inspector edit, animated double-click zoom into note view + back arrow.
- [ ] Off-canvas wikilinks are hidden on the canvas; rendered only when both endpoints are placed.
- [ ] Multiple links between the same pair render as parallel offset curves.
- [ ] Marquee multi-drag commits as one transaction.
- [ ] Tab list + active tab + per-canvas pan/zoom persist across app restarts per vault.
- [ ] Primary flow robot test passes end-to-end against a real `memex` binary + vault.
- [ ] Widget tests cover the screen-level error and edge behaviors listed under "Test-type split."
- [ ] `cargo test --workspace`, `cargo clippy --workspace --all-targets -- -D warnings`, and `cd app && flutter analyze && flutter test` all clean.
- [ ] `docs/canvas.md` exists; README + `docs/wikilinks.md` link to it.
- [ ] Manual verification screenshot of the Primary flow attached to the PR.
</done_when>
