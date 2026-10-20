# Acceptance test — canvas slice

Manual journey to confirm the canvas slice (Phases 1–5) works end-to-end
through both the Flutter app and the CLI / MCP server.

## Prereqs

- `memex` CLI installed at `~/.cargo/bin/memex` (re-run
  `cargo install --path crates/memex-mcp --locked --force` after changes).
- Flutter macOS app built (`cd app && flutter run -d macos`).
- A fresh vault: `memex init ~/Documents/MemexCanvasAcceptance`.
  (If you reuse an older vault, it'll auto-migrate to v4 on first open.)
- Two seed notes for the journey:
  ```bash
  printf '# Local-first principles\n\nThe canonical idea.\n' \
    | memex add --vault ~/Documents/MemexCanvasAcceptance --title "Local-first principles"
  printf '# CRDT survey\n\nNotes on Yjs, Automerge, Loro.\n' \
    | memex add --vault ~/Documents/MemexCanvasAcceptance --title "CRDT survey"
  ```

## 1. Create a canvas from the rail

1. Launch the app, open `MemexCanvasAcceptance`.
2. **Expected**: the left rail has a `canvases · 0  + new` panel above
   the existing notes tree.
3. Click `+ new`. Type `Research Q2` in the dialog; press Create.
4. **Expected**: `Research Q2` appears in the canvases panel and a new
   tab opens with the empty canvas (`Drag a note from the left to get started.`).

## 2. Place two notes on the canvas

1. From the notes tree, drag `Local-first principles` onto the canvas
   somewhere in the upper-left quadrant. **Expected**: a node card
   appears at the drop point with the note's title.
2. Drag `CRDT survey` onto the canvas, somewhere to the right of the
   first node. **Expected**: a second node card appears.
3. Try dragging `Local-first principles` onto the canvas again.
   **Expected**: the drop is silently rejected (no second copy of the
   node appears).
4. Drag one of the nodes to a new position; release. **Expected**: the
   node stays where you dropped it. Re-open the canvas (close + reopen
   the tab) and the position is preserved.

## 3. Draw a typed link

1. Hover over the `CRDT survey` node. **Expected**: a small blue circle
   appears on its right border (the edge handle).
2. Press on the handle and drag to the `Local-first principles` node.
   **Expected**: a live blue line follows the cursor.
3. Release over the target. **Expected**: a popover appears with kind
   chips and a label field. Pick `extends`, type `builds on this`, click Add.
4. **Expected**: a curve appears from `CRDT survey` to `Local-first principles`
   with the label `builds on this` rendered at its midpoint. An arrow head
   points at the target.
5. Re-open `CRDT survey` in the notes editor (click it in the rail).
   **Expected**: the body now ends with frontmatter or `## Auto-added links`
   containing `[[Local-first principles~extends|builds on this]]` (depending
   on the destination rule per `docs/wikilinks.md`).

## 4. Edit the link via the canvas

1. Back in the `Research Q2` canvas tab, click the line you just drew.
   **Expected**: an `Edit link` inspector appears in the top-right with
   `extends` selected and the label populated.
2. Change the kind to `references`. Clear the label. Click Save.
3. **Expected**: the line redraws without a label and the source body
   (verifiable via the editor) now contains `[[Local-first principles]]`
   in the appropriate destination (auto-added section for `references`).

## 5. Self-link is rejected

1. Hover the `CRDT survey` node; drag from its edge handle back onto
   itself. **Expected**: no popover opens; a snackbar reads
   "Can't link a note to itself." The line ghost vanishes on release.

## 6. Zoom into a note from the canvas

1. Double-click the `Local-first principles` node.
2. **Expected**: the canvas tab smoothly transitions into the existing
   note editor for that note. A `← back to canvas` chip appears in the
   top-left of the editor area.
3. Edit the body — add a sentence. **Expected**: status indicator
   transitions `unsaved → saving → saved` like normal.
4. Click `← back to canvas`. **Expected**: animation back to the canvas
   at the same pan/zoom; the line is still there.

## 7. Multiple lines between the same pair

1. Draw a second link from `CRDT survey` → `Local-first principles`,
   this time with kind `contradicts` and label `tradeoffs`.
2. **Expected**: the canvas shows two parallel curves between the same
   pair, each with its own label. Click each line separately —
   **expected**: the inspector reflects the kind/label you clicked,
   not the other.

## 8. Off-canvas wikilinks are hidden

1. From the editor on `CRDT survey`, type `Also see [[Local-first principles]]`
   (a duplicate link). Save.
2. Back in the canvas tab: **expected**: a *third* parallel curve appears
   (now three links between the same pair).
3. Add a new note titled `Something else` via the rail. In `CRDT survey`
   add `[[Something else]]`. Save.
4. Back in the canvas: **expected**: NO line is drawn from `CRDT survey`
   to `Something else`, because the target isn't placed. (Open
   `CRDT survey` in the editor — the right Connections panel still lists it.)

## 9. CLI / MCP round-trip

1. From a terminal:
   ```bash
   memex canvas ls --vault ~/Documents/MemexCanvasAcceptance
   ```
   **Expected**: JSON listing `Research Q2` with a `node_count` of 2
   (or more if you placed extras).
2. Get the canvas detail:
   ```bash
   memex canvas get --vault ~/Documents/MemexCanvasAcceptance \
       --canvas-id <ULID from step 1>
   ```
   **Expected**: JSON with the two placed nodes and the edges between
   them (kinds, labels, positions).
3. From Claude Desktop (or an MCP inspector), call `list_canvases`
   and `get_canvas`. **Expected**: same data, shaped identically to
   the CLI output (`canvas_id`, `title`, `nodes[]`, `edges[]`).

## 10. Delete a canvas

1. From a terminal, grab the canvas's current `version` from
   `memex canvas ls`, then:
   ```bash
   memex canvas rm --vault ~/Documents/MemexCanvasAcceptance \
       --canvas-id <ULID> --expected-version <N>
   ```
2. **Expected**: success. `memex canvas ls` now returns an empty array.
3. In the running app, re-open the vault. **Expected**: the
   `Research Q2` tab is gone and the canvases panel shows `0`. The two
   underlying notes are still present and unchanged.

## What's intentionally not covered here

- Marquee multi-select drag (not implemented in v1).
- Auto-layout (intentionally manual-only in v1).
- A delete-node UI affordance (use `memex canvas remove`).
- Bulk edge edits and edge deletion via the canvas (remove the
  wikilink from the source note's body in the editor instead).
