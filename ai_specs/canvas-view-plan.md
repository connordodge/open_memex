# Canvas View — Implementation Plan

## Overview

Visual, tabbed canvas board for Open Memex. Concept=note, line=wikilink. Rust core+MCP add canvas CRUD; Flutter shell becomes tabbed with two-list rail and an `InteractiveViewer`+`CustomPaint` canvas.

**Spec**: `ai_specs/canvas-view-spec.md` (read for full requirements).

## Context

- **Structure**: Rust workspace (`crates/memex-core`, `crates/memex-mcp`) + Flutter macOS app (`app/`). Feature-by-file in core; widget-and-state folders in Flutter.
- **State management**: `flutter_riverpod ^2.5.1`. Refresh signal: bump `vaultRevisionProvider` after writes; read-paths `ref.watch` it. Reads via `VaultDb` (read-only SQLite); writes via `MemexCli` subprocess.
- **Reference implementations**:
  - Rust: `crates/memex-core/src/notes.rs` (CRUD + optimistic concurrency), `crates/memex-core/src/links.rs` (read shapes + `row_to_link`), `crates/memex-core/src/schema.rs` V1/V2 single-transaction migration, `crates/memex-mcp/src/tools.rs` AddLink tool pattern, `crates/memex-mcp/src/main.rs` clap (flat — nested subcommands introduced this PR).
  - Flutter: `app/lib/src/widgets/sidebar.dart` rail + `_TreeItem`, `app/lib/src/widgets/note_editor.dart` (debounced save), `app/lib/src/widgets/kind_chip.dart` (kind UI), `app/lib/src/memex_cli.dart` (`addLink`, `_run`, JSON envelopes), `app/lib/src/state/vault_state.dart` (provider conventions), `app/lib/src/db.dart` (read-only SQLite reads).
  - Acceptance shape: `docs/acceptance-test.md` (mirror for `docs/canvas-acceptance.md`).
- **Commit convention**: `feat(app|core|mcp): canvas Phase N — short summary` (matches existing `feat(app): wikilinks Phase N — …`).
- **Assumptions / gaps resolved before planning**:
  - Spec says "on-disk app-state JSON file" — no such file. Settings live in `SharedPreferences`. **Decision: introduce `<vaultPath>/.memex/ui_state.json` for per-vault tab+viewport state.** Keeps DB ownership clean; survives `flutter clean`.
  - Spec says "reuse autocomplete kind-chip path" — kind-chip mutates the editor's `TextEditingController` and relies on its 500ms debounce. **Decision: canvas drag-to-link calls `MemexCli.addLink` directly** (spec's own Implementation Notes prefer this).
  - Edge inspector needs to edit `kind`/`label` on an existing wikilink. No such narrow CLI today. **Decision: add `memex update-link --link-id ... [--kind ...] [--label ...]` in Phase 2 (CLI + MCP + core).**
  - `rightPanelOpenProvider` lives in `main_window.dart`, not `vault_state.dart` — move during Phase 3 refactor.
  - No `InMemoryMemexCli`/`InMemoryVault` fakes exist. **Decision: extract `MemexCli` interface in Phase 3; provide `InMemoryMemexCli` under `app/test/fakes/`.**
  - `flutter-patterns-researcher` knowledge base not installed on this machine — proceed with Flutter built-ins per spec + codebase patterns.

## Plan

### Phase 1: Core canvas data model + V4 migration

- **Goal**: V4 schema, `canvas.rs` CRUD, no MCP/UI yet. Vertical proof: programmatic create→place→link→get→delete round-trips, edges filtered to placed pairs.
- [x] `crates/memex-core/src/schema.rs` — add `V4` SQL const (`canvases`, `canvas_nodes` with FK cascades, `idx_canvas_nodes_note`, `UNIQUE(canvases.title)`); bump `APP_SCHEMA_VERSION = 4`; extend `apply()` with `current < 4` gated transaction (mirror V1/V2 shape).
- [x] `crates/memex-core/src/canvas.rs` (new) — types `CanvasId` (ULID newtype mirroring `NoteId`), `Canvas`, `CanvasSummary`, `CanvasNode`, `CanvasEdge`, `CanvasDetail`. Free functions: `create_canvas`, `list_canvases`, `get_canvas`, `rename_canvas`, `delete_canvas`, `add_to_canvas`, `remove_from_canvas`, `move_node`, `move_nodes_batch`.
- [x] `crates/memex-core/src/canvas.rs` — `get_canvas` SQL: `SELECT … FROM links WHERE from_note_id IN (?,…) AND to_note_id IN (?,…)` over placed `note_id`s; reuse `links::row_to_link` shape. Do **not** add this query to `links.rs`.
- [x] `crates/memex-core/src/lib.rs` — `pub mod canvas;` + `pub use canvas::{Canvas, CanvasNode, CanvasEdge, CanvasId, CanvasSummary, CanvasDetail};`.
- [x] `crates/memex-core/src/canvas.rs` — clock seam: `pub trait Clock { fn now_ms(&self) -> i64; }` with default impl using `crate::vault::now_unix_ms`; functions take `&dyn Clock` only where needed (or a `SystemClock` zero-sized default to avoid plumbing — TBD during TDD).
- [x] `crates/memex-core/tests/migration_v4.rs` (new) — open V3 vault, run `schema::apply`, assert tables exist and prior notes/links intact.
- [x] `crates/memex-core/tests/canvas_integration.rs` (new) — vault round-trip tests for each public fn.
- [x] TDD: `create_canvas` returns canvas with id+timestamps, rejects duplicate title with `TitleConflict`.
- [x] TDD: `list_canvases` orders by `updated_at DESC`, includes `node_count`.
- [x] TDD: `add_to_canvas` is idempotent on `(canvas_id, note_id)` (second call returns existing row, position unchanged), rejects unknown note_id/canvas_id, bumps `canvases.updated_at`.
- [x] TDD: `move_node` updates position, bumps `updated_at`, no-op for missing placement.
- [x] TDD: `move_nodes_batch` is single-transaction (deliberately invalid row inside batch rolls back the whole batch).
- [x] TDD: `remove_from_canvas` removes placement only, leaves note + links untouched.
- [x] TDD: `rename_canvas` honors `expected_version`, returns `VersionConflict` on mismatch, rejects duplicate title.
- [x] TDD: `delete_canvas` cascades `canvas_nodes` only; existing notes + links untouched.
- [x] TDD: `get_canvas` on empty canvas returns no nodes/edges.
- [x] TDD: `get_canvas` returns edges only between placed nodes (off-canvas wikilinks hidden).
- [x] TDD: `get_canvas` returns multiple edges between same pair (e.g. `extends` + `references`) as separate rows.
- [x] TDD: `get_canvas` excludes ghost wikilinks (`to_note_id IS NULL`).
- [x] TDD: FK cascade — deleting a note removes its placements across canvases; deleting a canvas removes its placements only.
- [x] TDD: V4 migration applies cleanly to a V3 vault, prior data intact.
- [x] Verify: `cargo test --workspace && cargo clippy --workspace --all-targets -- -D warnings`.

### Phase 2: CLI + MCP tools + `update-link` primitive

- **Goal**: All canvas ops reachable from terminal + MCP. Add the missing `update-link` primitive that the edge inspector needs in Phase 4. JSON output from day 1.
- [x] `crates/memex-core/src/links.rs` — new `update_link(vault, link_id, new_kind?, new_label?) -> LinkRow`: rewrites the matching wikilink occurrence in the source note's body via the existing extractor/serializer round-trip; transactional; bumps source note `version`. Returns updated `LinkRow`.
- [x] `crates/memex-mcp/src/main.rs` — introduce nested clap: `Canvas { #[command(subcommand)] action: CanvasAction }` variant + `enum CanvasAction { New, Ls, Get, Rename, Rm, Add, Remove, Move }`. Add `UpdateLink { … }` flat variant alongside `AddLink`.
- [x] `crates/memex-mcp/src/main.rs` — `cmd_canvas_*` helpers (printf JSON output, mirror `cmd_add_link` shape); `cmd_update_link`.
- [x] `crates/memex-mcp/src/tools.rs` — inside existing `#[tool_router]` impl block, add `#[tool]` methods: `list_canvases`, `get_canvas`, `create_canvas`, `add_to_canvas`, `remove_from_canvas`, `move_node`, `delete_canvas`, **plus** `update_link`. One `Params` struct + one `Envelope` struct per tool. Reuse `err_payload`, `group_links_by_kind` (for `get_canvas` edges if grouped form chosen, else inline flat list).
- [x] `crates/memex-mcp/tests/tool_smoke.rs` — add round-trip tests for each new tool (direct method calls, JSON parse).
- [x] `crates/memex-mcp/tests/cli_canvas.rs` (new) — `memex canvas new/ls/get/add/move/remove/rm` exit-0 + JSON shape; `memex update-link` round-trip.
- [x] TDD: `update_link` changes only kind, only label, or both; preserves alias; rejects unknown `link_id`; honors source-note version.
- [x] TDD: `update_link` rewrites `[[Title]]` → `[[Title~kind]]`, `[[Title~old]]` → `[[Title~new]]`, plus alias preserve/clear over the four wikilink shapes in `docs/wikilinks.md`.
- [x] TDD: `list_canvases` MCP tool returns expected JSON shape (compare to documented schema in spec).
- [x] TDD: `get_canvas` MCP tool returns nodes + edges; invalid `canvas_id` returns structured `err_payload`.
- [x] TDD: `create_canvas` MCP duplicate-title returns `err_payload("create_canvas.title_conflict", …)`.
- [x] TDD: `add_to_canvas` MCP defaults `x=0.0, y=0.0` when omitted.
- [x] TDD: `delete_canvas` MCP honors `expected_version`.
- [x] Verify: `cargo test --workspace && cargo clippy --workspace --all-targets -- -D warnings`.

### Phase 3: Tabbed workspace shell + rail refactor (no canvas tab yet)

- **Goal**: Replace `MainWindow` with `Workspace` (tabs of notes). Two-list rail (canvas section + notes tree, in the existing sidebar chrome). Tabs persist. Existing note flows unchanged. Lays the chassis for Phase 4.
- [x] `app/lib/src/screens/workspace.dart` (new) — top-level shell: `Sidebar` + `_WorkspaceTabBar` + `_TabBody` + `RightPanel`. Note tab embeds existing `NoteEditor` + `RightPanel`. Canvas tab renders a Phase-4 placeholder.
- [x] `app/lib/main.dart` — route to `Workspace`; delete `main_window.dart` outright.
- [x] `app/lib/src/state/tabs_state.dart` (new) — sealed `WorkspaceTab` (`NoteTab`, `CanvasTab`); `tabsProvider: StateNotifierProvider<TabsNotifier, TabsState>`; `activeTabProvider`. Notifier exposes `openOrFocus`, `close`, `setActive`. Note: `tabsState` carries `(tabs, activeIndex)` together; LRU eviction past `kMaxOpenTabs = 20`.
- [x] `app/lib/src/state/ui_state_store.dart` (new) — per-vault JSON read/write at `<vaultPath>/.memex/ui_state.json` (tabs[], activeIndex, per-canvas `{dx, dy, zoom}`). Atomic write via tmp+rename, serialized via an internal future queue.
- [x] `app/lib/src/state/vault_state.dart` — `rightPanelOpenProvider` lives here; add `canvasesProvider` + `canvasDetailProvider(canvasId)` family.
- [x] `app/lib/src/widgets/sidebar.dart` — refactored to host a `Canvases` panel above the existing notes tree. Note tap → `tabsNotifier.openOrFocus(NoteTab)`; canvas tap → `openOrFocus(CanvasTab)`. New "+ new canvas" affordance with title prompt.
- [N/A] `notes_rail.dart` / `canvases_rail.dart` (deferred) — kept the rails inline in `sidebar.dart` to preserve the existing visual chrome. Keys `Key('notes-rail')` and `Key('canvases-rail')` still present.
- [x] Tab strip lives in `workspace.dart` as `_WorkspaceTabBar` (not extracted to its own file). Keys: `Key('workspace-tab-bar')`, `Key('tab-$tabId')`, `Key('tab-close-$tabId')`. Middle-click close deferred.
- [x] Tab body lives in `workspace.dart` as `_TabBody`. CanvasTab → placeholder pending Phase 4.
- [x] `app/lib/src/db.dart` — `listCanvases()` + `getCanvasDetail(canvasId)` with IN-clause edge join mirroring core.
- [x] `app/lib/src/memex_cli.dart` — added canvas wrappers (`createCanvas`, `renameCanvas`, `deleteCanvas`, `listCanvases`, `getCanvas`, `addToCanvas`, `removeFromCanvas`, `moveNode`) + `updateLink`, all JSON-parsing. Concrete class kept (no interface extraction); Dart `implements MemexCli` is enough for Phase 4 fakes.
- [N/A] `InMemoryMemexCli` fake — deferred to Phase 4 where widget tests for the canvas view will need it. Phase 3 tests cover `TabsNotifier` and `UiStateStore` directly without going through `MemexCli`.
- [N/A] `app/test/journeys/` scaffolding — deferred to Phase 4 (no robot test yet for note-only flow; chassis behavior covered by unit tests).
- [x] TDD: opening a note via the sidebar adds a NoteTab and emits the selection.
- [x] TDD: opening an already-open tab switches to it without duplicating.
- [x] TDD: closing the active tab activates the previous tab; closing the only tab returns to empty state.
- [x] TDD: 21st tab open evicts oldest non-active tab (LRU).
- [x] TDD: `UiStateStore` writes/reads round-trip; corrupted file falls back to empty; invalid viewport zoom dropped; unknown tab kinds dropped.
- [N/A] Robot: `note_tab_flow_test.dart` — deferred to Phase 4 alongside the canvas primary-flow journey test. Phase 3 tab-flow behavior is covered by direct `TabsNotifier` unit tests against the real store on a tmp filesystem.
- [x] Verify: `cd app && flutter analyze && flutter test` (15 tests pass; no analyzer issues).

### Phase 4: Canvas view (drag-from-rail, drag-to-link, edge inspector, animated zoom)

- **Goal**: Full canvas tab. Vertical proof: primary-flow robot test (create canvas → place 2 notes → drag-link with label → double-click zoom → edit → back → assert line persists).
- [ ] `app/lib/src/state/canvas_state.dart` (new) — `canvasesProvider: FutureProvider<List<CanvasSummary>>` (watches `vaultRevisionProvider`); `canvasDetailProvider(canvasId): FutureProvider.family` (re-fetched on revision bump); `canvasViewportProvider(canvasId): StateProvider.family<{offset, zoom}>` (in-memory; persisted via `ui_state_store`); `canvasSelectionProvider(canvasId): StateProvider.family<CanvasSelection>` (selected node ids + selected edge id).
- [ ] `app/lib/src/widgets/canvas_view.dart` (new) — `ConsumerStatefulWidget`; `InteractiveViewer` (`min 0.1`, `max 4`, `boundaryMargin: infinite`) wrapping a `Stack` of `Positioned` nodes; `RepaintBoundary` over the edges layer (`CustomPaint`); `RepaintBoundary` over each node; empty-state child when zero placements. `Key('canvas-view-$canvasId')`.
- [ ] `app/lib/src/widgets/canvas_node.dart` (new) — node card showing title + small outbound-kind summary chip; hover reveals edge-handle pip on nearest border; `Draggable` for reposition (debounced 200ms persist via `moveNode`); double-click triggers zoom-in animation. `Key('canvas-node-$noteId')`, `Key('edge-handle-$noteId')`, `Key('zoom-in-target-$noteId')`.
- [ ] `app/lib/src/widgets/canvas_edge_painter.dart` (new) — `CustomPainter` over canvas-space coordinates; one cubic Bézier per `links` row; parallel offsets for multi-edge pairs; label/kind chip painted at midpoint; arrow head for direction; `shouldRepaint` returns true only when edge list or selection changes. Expose `hitTestEdge(localPosition, tolerancePx: 6) -> linkId?` for the canvas to consume.
- [ ] `app/lib/src/widgets/canvas_edge_inspector.dart` (new) — floating panel anchored to selected edge; kind chips (built-ins + `More…` user-defined picker driven by `linkKindsProvider`); label `TextField`; saves via `cli.updateLink(linkId, kind, label)` then bumps `vaultRevisionProvider`. `Key('edge-inspector')`, `Key('edge-kind-chip-$kind')`, `Key('edge-label-input')`.
- [ ] `app/lib/src/widgets/edge_creation_overlay.dart` (new) — overlay above `InteractiveViewer` that owns the ghost-line during drag-to-link; converts pointer to canvas coords using the `TransformationController`; on drop computes target node under pointer (canvas coords) and renders `LinkPopover`. Anti-pattern guard: never start drag from rail items (those are placement drags, not link drags).
- [ ] `app/lib/src/widgets/link_popover.dart` (new) — kind chip row + optional label `TextField` + confirm/cancel. Confirm → `cli.addLink(fromId, toId, kind, label)`. `Key('link-popover')`, `Key('link-popover-confirm')`, `Key('link-popover-cancel')`.
- [ ] `app/lib/src/widgets/tab_body.dart` — implement `CanvasTab` path: render `CanvasView(canvasId)` or, when "zoomed in," render `NoteEditor` for the selected node; manage the `AnimatedSwitcher` + `Matrix4` interpolated transform between the two. `Key('zoom-out-back-button')`.
- [ ] `app/lib/src/widgets/canvases_rail.dart` — wire "+ New canvas" → modal text input → `cli.createCanvas(title)` → `tabsNotifier.openOrFocus(CanvasTab(newId))`.
- [ ] `app/lib/src/widgets/notes_rail.dart` — wrap each note row in `Draggable<NoteId>` so drops land on `CanvasView`'s `DragTarget<NoteId>`. Drop converts screen→canvas coords, calls `cli.addToCanvas(canvasId, noteId, x, y)`, rejects if already placed (silent + pulse).
- [ ] `app/lib/src/widgets/canvas_view.dart` — wrap with `DragTarget<NoteId>` (`onWillAccept` rejects already-placed); on drop call `addToCanvas` with computed canvas coords.
- [ ] `app/lib/src/widgets/canvas_node.dart` — double-click → set `canvasViewportProvider(canvasId)` snapshot, trigger `AnimatedSwitcher` to editor; back button reverses with same snapshot.
- [ ] `app/test/fakes/in_memory_memex_cli.dart` — extend with canvas + `addLink` + `updateLink` recorders.
- [ ] TDD: `canvasDetailProvider` re-fetches when `vaultRevisionProvider` bumps.
- [ ] TDD: drag-from-`NotesRail` over `CanvasView` calls `addToCanvas` with computed canvas coords; subsequent drag of same note is rejected with pulse animation.
- [ ] TDD: drag from `edge-handle-A` to `canvas-node-B` opens `link-popover`; confirm calls `addLink(A, B, kind, label)`; self-link (A→A) is silently rejected (no popover, toast).
- [ ] TDD: dragging a node debounces a single `moveNode` call (200ms; injected as 0 in tests).
- [ ] TDD: marquee multi-select drag commits one `moveNodesBatch` call.
- [ ] TDD: `canvas_edge_painter.hitTestEdge` returns the correct `linkId` within 6px corridor, null beyond.
- [ ] TDD: multiple wikilinks between same pair render as two distinct hit-test regions.
- [ ] TDD: clicking an edge opens inspector populated with current kind+label; saving calls `updateLink` and reflects new values on next render.
- [ ] TDD: double-click on canvas node animates into `NoteEditor` for that note within the same tab; back arrow returns to canvas at prior pan/zoom.
- [ ] TDD: animation duration is overridable (test injects `Duration.zero` + pumps once; assert state at both ends without flake).
- [ ] TDD: off-canvas wikilink targets do not render lines (only edges with both endpoints placed render).
- [ ] TDD: corrupt `ui_state.json` viewport falls back to default `{offset: (0,0), zoom: 1}`.
- [ ] Robot: `canvas_primary_flow_test.dart` — create canvas → drag two notes from rail → drag-link with kind=extends + label → assert edge rendered with label → double-click target → editor visible → edit body → back → edge still present + label intact. Uses real (in-memory) `MemexCli` fake + animation Duration.zero.
- [ ] Verify: `cd app && flutter analyze && flutter test`.

### Phase 5: Polish, docs, manual verification

- **Goal**: Documentation; manual primary-flow walkthrough; performance smoke.
- [ ] `docs/canvas.md` (new) — user-facing: what canvases are, drag/place/link/zoom flows, off-canvas hiding policy, multi-edge rendering, MCP tool list, current limits.
- [ ] `docs/canvas-acceptance.md` (new) — manual journey (mirror `docs/acceptance-test.md` style) for each phase.
- [ ] `README.md` — append a "Canvas" bullet under "What works today"; link to `docs/canvas.md`.
- [ ] `docs/wikilinks.md` — append cross-reference to canvas section ("lines on a canvas are wikilinks").
- [ ] Manual: run `flutter run -d macos` against a real vault; walk primary flow; capture screenshot via `act-flutter-screenshot`.
- [ ] Manual: open `memex serve` in the MCP inspector; verify `list_canvases` / `get_canvas` / `create_canvas` / `add_to_canvas` / `update_link` round-trip.
- [ ] Manual: perf smoke at ~200 nodes / 400 edges (synthetic vault); document FPS; record if degraded earlier than 500/1000 target.
- [ ] Verify: full suite — `cargo test --workspace && cargo clippy --workspace --all-targets -- -D warnings && cd app && flutter analyze && flutter test`.

## Risks / Out of scope

- **Risks**:
  1. **Animated zoom-in interaction with `InteractiveViewer`**: `Hero` is fragile across `InteractiveViewer` transforms; plan uses `AnimatedSwitcher` + `Matrix4` interpolation, but if jitter persists in practice, fall back to a non-animated cut + log a follow-up.
  2. **Edge hit-test reliability**: 6px Bézier corridor may be too tight on dense graphs; tune in Phase 4 based on robot test stability.
  3. **`update_link` body-rewrite correctness**: rewriting one wikilink occurrence by `link_id` must preserve all other wikilinks exactly; TDD must cover each of the four wikilink shapes per `docs/wikilinks.md`.
- **Out of scope**:
  - Force-directed / any auto-layout (manual only per spec Q4).
  - Off-canvas link badges or ghost stub nodes (hidden entirely per spec Q2).
  - Ad-hoc "sticky" concepts not backed by a note.
  - Mobile / Windows / Linux.
  - Multi-window canvases.
  - Transclusion on canvas (`![[Title]]`).
  - CRDT/sync for canvas positions.
  - Performance work above 500 nodes / 1000 edges.
