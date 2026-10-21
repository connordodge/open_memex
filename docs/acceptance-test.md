# Acceptance test — wikilinks slice

Manual journey to confirm the wikilinks slice (Phases 1–4) works end-to-end through both the Flutter app and Claude Desktop.

## Prereqs

- `memex` CLI installed at `~/.cargo/bin/memex` (re-run `cargo install --path crates/memex-mcp --locked --force` if you've made changes).
- Flutter macOS app built (`cd app && flutter build macos --debug`) and runnable.
- Claude Desktop installed; `~/Library/Application Support/Claude/claude_desktop_config.json` configured per [`claude-desktop-setup.md`](./claude-desktop-setup.md) and pointed at the test vault path.
- A fresh vault: `memex init ~/Documents/MemexAcceptance`.

## 1. Type a wikilink in the Flutter editor

1. Launch the app, open `MemexAcceptance`.
2. Hit the `+` button to create "Note A". Type some prose.
3. Hit `+` again, name the new note "Note B". In its body type `Some prose, see [[Note A]]`.
4. **Expected**: while typing `[[`, a popover opens; "Note A" appears as a match. Press Enter. The body becomes `…see [[Note A]]` with the caret after `]]`.
5. **Expected**: a chip appears near the editor with `REFERENCES / EXTENDS / CONTRADICTS / EXAMPLE-OF` buttons + `MORE…`. Click `EXTENDS`. The body rewrites to `…see [[Note A~extends]]`.
6. Save propagates within 500ms; status indicator goes `unsaved → saving → saved`.

## 2. See the link in the Connections panel

1. Open Note A.
2. **Expected**: in the right panel, the Connections tab shows the eyebrow `1 outgoing · 1 backlinks` and a section labelled `EXTENDED BY` with "Note B" listed under it.
3. Click "Note B" in the panel. Editor switches to Note B.

## 3. Create-on-the-fly via the popover

1. In Note A's body, type `Inspired by [[Vannevar`. The popover shows no exact match.
2. **Expected**: the last item in the popover is **"+ Create new note titled "Vannevar""**. Press Enter to select it.
3. **Expected**: "Vannevar" appears in the sidebar's note list. The body now contains `…[[Vannevar]]`.
4. Click the chip's `MORE…` button → type `inspired-by` → submit. Body rewrites to `…[[Vannevar~inspired-by]]`.

## 4. Frontmatter relationships

1. Edit Note B and prepend YAML frontmatter:
   ```yaml
   ---
   extends:
     - [[Note A]]
   contradicts:
     - [[Vannevar]]
   ---
   ```
2. Save. Open the **Vannevar** note.
3. **Expected**: Connections panel shows Note B under `CONTRADICTED BY`.

## 5. Section-based grouping

1. In Note A, append:
   ```markdown
   ## Contradicts

   [[Note B]]
   [[Vannevar]]
   ```
2. Save. Open Note B.
3. **Expected**: Connections panel shows Note A under `CONTRADICTED BY` (the section heading inherits kind for everything under it, even though the wikilinks themselves don't carry `~contradicts`).

## 6. Title rename rewrites linkers

In a terminal:

```bash
$ memex links --vault ~/Documents/MemexAcceptance --note-id <Note A's id> --dir out
```

Confirm the tree shows the outgoing edges. Then:

```bash
$ memex update --vault ~/Documents/MemexAcceptance \
    --note-id <Note A's id> \
    --expected-version 1 \
    --title "Note A (renamed)" < /dev/null
```

(Pipe `/dev/null` because update reads the body from stdin; we want to keep it empty by passing whatever's already there. To preserve content, replace `< /dev/null` with the actual body via stdin.)

Open Note B.

**Expected**: every `[[Note A]]` in Note B's body and frontmatter is now `[[Note A (renamed)]]`. Backlinks panel still shows the relationship.

## 7. AI side — `get_note(include_backlinks)`, `neighbors`, `add_link`

In Claude Desktop (with `memex` registered as an MCP server):

a) Ask: *"What links to Note B?"*
   - **Expected**: Claude calls `get_note(<Note B's id>, include_backlinks=true)` and replies with the source notes grouped by kind (e.g., "Note A extends this; Note A also contradicts this via the section heading").

b) Ask: *"What notes are connected to Note A within two hops?"*
   - **Expected**: Claude calls `neighbors(note_id, depth=2)` and walks the graph. The reply names "Note B", "Vannevar", and any further-out notes if present.

c) Ask: *"Add a 'requested-by' link from Note A to a new note titled 'Investor request 04-22'."*
   - **Expected**: Claude calls `create_note` for "Investor request 04-22" then `add_link(from=Note A, to=<new id>, kind="requested-by")`. The new link appears in Note A's frontmatter as `requested-by:\n  - [[Investor request 04-22]]`. The Flutter app's right panel updates within ~2s and shows `REQUESTED-BY` as a new kind group.

d) Ask: *"Add the same link again."*
   - **Expected**: Claude calls `add_link` again; the response carries `was_existing: true` and the source markdown is unchanged (no duplicate row, no markdown mutation).

## 8. Ghost links

1. Delete `Vannevar` via direct SQLite (or by editing — there's no GUI delete yet):
   ```bash
   $ sqlite3 ~/Documents/MemexAcceptance/memex.db "DELETE FROM notes WHERE title='Vannevar'"
   ```
2. Force a reindex on the linkers:
   ```bash
   $ memex ls --vault ~/Documents/MemexAcceptance
   # then rewrite-save Note A or Note B via the GUI to trigger reindex
   ```
3. Open the right panel.
   - **Expected**: outgoing wikilinks pointing at the deleted "Vannevar" show a `GHOST` tag and the `fileX` icon. The note can no longer be navigated to from the panel until you create it again — typing `[[Vannevar]]` in any new note → "+ Create" path resurrects it.

## Pass criteria

- All eight scenarios behave as described.
- `cargo test --workspace` green.
- `flutter analyze` clean; `flutter test` green.
- No console errors during the manual journey.

## Findings template

Capture in `docs/wikilinks-debrief.md`:

- What surprised you?
- What was slower / clunkier than expected?
- What's the next user friction worth fixing?
