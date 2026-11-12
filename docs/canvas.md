# Canvases in Open Memex

A **canvas** is a user-curated visual board. You place notes onto it as
nodes, drag them around, and the wikilinks between any two placed notes
render as labelled lines. Canvases live in the same vault as your notes
and are reachable from both the desktop app and the MCP server.

This is the user-facing reference. The internal design is in
[`ai_specs/canvas-view-spec.md`](../ai_specs/canvas-view-spec.md).

## The mental model

- **Concept = Note.** Every node on a canvas is one of your real notes.
  Editing a node's text edits the underlying note.
- **Line = Wikilink.** Every line is a real `[[Target~kind|label]]`
  wikilink in the source note's body or frontmatter. Drawing a line
  *writes* a wikilink; deleting an edge means rewriting the source note.
- **Curated.** You decide which notes appear on which canvas. A note
  can appear on multiple canvases (each gets its own position).
- **Off-canvas wikilinks are hidden.** If a placed note links to a note
  that *isn't* on the same canvas, no line is drawn here — open the
  note to see the full Connections panel.

## What you can do

### Create a canvas

In the desktop app, the left rail has a `canvases` section above the
notes tree. Click `+ new`, type a title, press Enter. The canvas opens
as a new tab.

From the CLI:

```bash
memex canvas new --vault ~/Documents/MyMemex --title "Research Q2"
```

### Place a note

Drag any note row from the notes section of the left rail onto an open
canvas. The note becomes a draggable node at the drop position.
Dragging a note that's already on the canvas is silently rejected —
each canvas has at most one placement per note.

From the CLI:

```bash
memex canvas add --vault ~/Documents/MyMemex \
    --canvas-id <ULID> --note-id <ULID> --x 240 --y 180
```

### Move a node

Drag the node around. Positions are persisted ~200ms after you stop
moving (so a quick drag doesn't fire many writes). Last-write-wins.

```bash
memex canvas move --vault ~/Documents/MyMemex \
    --canvas-id <ULID> --note-id <ULID> --x 800 --y 400
```

### Draw a link

Hover a node — a small blue handle appears on its right border. Drag
from the handle to another node. On drop, a popover lets you pick the
`kind` (`references`, `extends`, `contradicts`, `example-of`, or any
existing user-defined kebab-case kind) and an optional label. Confirming
writes `[[Target~kind|label]]` into the source note via the same path
as `memex add-link` — the wikilink graph and the canvas never disagree.

Dropping back onto the source node is silently rejected ("can't link a
note to itself").

### Edit a link

Click on the line. A floating inspector appears in the top-right with
the link's current kind and label. Edit either, click Save, and the
wikilink in the source note's body is rewritten in place — the link
keeps its identity and the rest of the body is untouched.

Frontmatter-bound wikilinks (those that came from a YAML `extends:`
block or similar) accept label edits but not kind changes in v1 —
the kind lives in the YAML key, so moving it would mean restructuring
the YAML. Remove and re-add the link to change the kind on a
frontmatter wikilink.

From the CLI (mirrors the inspector exactly):

```bash
memex update-link --vault ~/Documents/MyMemex \
    --link-id <ULID> --kind extends --label "builds on this"
# or to clear the label:
memex update-link --vault ~/Documents/MyMemex \
    --link-id <ULID> --clear-label
```

### Multiple lines between the same two notes

If a source note links to a target with two different kinds (say
`extends` and `references`), the canvas renders two parallel curves
with their own labels. Each curve is independently selectable.

### Zoom into a note from the canvas

Double-click a node. The canvas tab smoothly transitions into the full
note editor for that note (250ms by default — configurable in code).
A back-arrow chip appears in the top-left; clicking it animates back
to the canvas at the same pan and zoom you left it at.

### Remove a node

There's no UI affordance for this in v1 — use the CLI:

```bash
memex canvas remove --vault ~/Documents/MyMemex \
    --canvas-id <ULID> --note-id <ULID>
```

This removes the placement only. The note and all its wikilinks are
untouched.

### Delete a canvas

```bash
memex canvas rm --vault ~/Documents/MyMemex \
    --canvas-id <ULID> --expected-version <N>
```

The `expected-version` matches the canvas's current `version` field
(visible in `memex canvas ls`) — this is optimistic-concurrency
protection so a concurrent rename doesn't get clobbered. Deleting
cascades placements only; notes and wikilinks survive.

## What the MCP server exposes

When `memex serve` is running, AI agents can:

- **`list_canvases()`** — list every canvas with id, title, timestamps,
  version, and `node_count`.
- **`get_canvas(canvas_id)`** — fetch a canvas's metadata, placed
  nodes (each with title + x/y), and edges (wikilinks whose source
  and target are both placed).
- **`create_canvas(title)`** — make a new empty canvas.
- **`add_to_canvas(canvas_id, note_id, x?, y?)`** — place a note.
  Idempotent on `(canvas_id, note_id)`. Returns the placement and
  `added`: `false` when the note was already placed and the existing
  placement came back.
- **`remove_from_canvas(canvas_id, note_id)`** — remove a placement.
  Returns `removed`: `false` when the note wasn't placed.
- **`move_node(canvas_id, note_id, x, y, z_order?)`** — reposition.
  Returns the placement and `changed`: `false` when `x`, `y` and the
  given `z_order` equal the current ones.
- **`delete_canvas(canvas_id, expected_version)`** — cascade-delete
  placements; notes and links untouched.
- **`update_link(link_id, kind?, label?, clear_label?)`** — same path
  as the canvas edge inspector. Returns the updated link and `changed`:
  `false` when every given value equals the current one, and then
  nothing is saved.

Combined, these let an agent assemble a canvas from a query
(e.g. "every note that contradicts X"), refine it spatially, and edit
the relationships without ever owning the underlying knowledge graph.

## Persisted UI state

The list of open tabs, the active tab, and each canvas's pan/zoom are
persisted per-vault in `<vaultPath>/.memex/ui_state.json`. This file
is *not* part of the vault DB and is never seen by MCP — it's
machine-local UI state.

## Documented limitations (v1)

- Canvas positions are last-write-wins; no CRDT, so two devices moving the same
  node at once are not merged. To use one vault from several devices, see
  [Hosted vault](hosted-vault.md).
- No marquee multi-select on the canvas; one node moves at a time.
- No auto-layout (force-directed, hierarchical, etc.). Positions are
  always manual.
- Off-canvas wikilinks are hidden entirely — no ghost stub nodes or
  "off-canvas" badges. Open the note to see its full Connections.
- Removing a node uses the CLI; the canvas UI has no delete affordance.
- Performance is targeted at ~500 nodes / ~1000 edges on Apple Silicon
  Macs. Above that, no v1 guarantee.
- The animated zoom-in uses `AnimatedSwitcher`, not `Hero`. The two
  views fade across instead of growing the node card into the editor.
