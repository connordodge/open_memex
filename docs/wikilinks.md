# Wikilinks in Open Memex

Open Memex gives you `[[Title]]` wikilinks in your markdown — the same syntax Obsidian and Roam use, with two extras: a **kind** (so the AI agent can tell *how* one note relates to another) and a **display alias** (so the rendered text can differ from the target title).

This doc is the user-facing reference.

## Syntax

| Form | What it means |
|---|---|
| `[[Title]]` | Reference to the note titled "Title". Kind defaults to `references`. |
| `[[Title~kind]]` | Reference, with a kind tag. `kind` is lowercase kebab-case. |
| `[[Title|alias]]` | Reference rendered as "alias". (Obsidian-compatible.) |
| `[[Title~kind|alias]]` | Both: typed reference, custom display text. |

The four characters `~`, `|`, `]`, and newline are forbidden inside titles. They're also forbidden in kinds (except `-`).

> Tilde (`~`) is the kind separator on purpose — pipe (`|`) belongs to display aliases (Obsidian-compat), and caret (`^`) is reserved for future block-reference / transclusion features.

## Kinds: built-in vs user-defined

There are two tiers:

**Built-in kinds** (these get curated section headings + frontmatter shortcuts and the AI knows what to do with them):

- `references` — the default; just "this note refers to that note."
- `extends` — "this note builds on that note."
- `contradicts` — "this note disagrees with that note."
- `example-of` — "this note is a concrete instance of that note's idea."

**User-defined kinds.** Anything matching `^[a-z][a-z0-9-]*$` up to 64 characters. `inspired-by`, `derived-from`, `requested-by`, whatever fits your thinking. They're first-class — they show up in `neighbors()` queries, in the right-panel Connections tab grouped by kind, and in the Flutter app's kind-chip "More…" picker (once you've used a kind once, it's there for next time).

The kind is normalized at write time: lowercased, whitespace runs collapsed to `-`, leading/trailing dashes stripped. So `Inspired By`, `inspired by`, and `inspired-by` all end up as `inspired-by`.

## Three ways to express a kind

### 1. Inline `~kind` syntax

The most precise. Works inside any prose:

```markdown
This `[[Local-first principles~extends]]` is what I'm building on.
We `[[Server-as-source-of-truth~contradicts]]` quite directly.
```

### 2. Curated section headings (built-ins only)

A wikilink under one of these headings inherits the kind without needing the `~kind` suffix in the wikilink itself:

| Heading (case-insensitive) | Kind |
|---|---|
| `## Contradicts` | `contradicts` |
| `## Extends`, `## Builds on`, `## Builds-on` | `extends` |
| `## Example of`, `## Examples` | `example-of` |
| `## See also`, `## References` | `references` |
| `## Open questions` | (no kind, but flips a `has_open_questions` flag the AI can query) |

Example:

```markdown
## Contradicts

[[Server-as-source-of-truth]]
[[Notion's collaborative model]]
```

Both wikilinks register as `contradicts` kind without you needing `~contradicts` in each one.

User-defined headings (e.g., `## Inspired by`) are deliberately **not** auto-mapped — too much magic. Put `[[X~inspired-by]]` in the body or use frontmatter.

### 3. YAML frontmatter

For "this whole note is in this relationship" rather than "this paragraph references that note":

```yaml
---
extends: [[Local-first principles]]
contradicts:
  - [[Server-as-source-of-truth]]
inspired-by:
  - [[As we may think · Vannevar Bush]]
  - [[Augmenting human intellect · Engelbart]]
---

# the rest of your note
```

Both built-in keys and user-defined kebab-case keys work. Bare-string values (`extends: Foo` without the `[[...]]`) are intentionally **ignored** — you must use the wikilink form so renames stay safe.

## Precedence

If multiple sources disagree, this is what wins:

1. Explicit inline `[[Title~kind]]` — always.
2. Section heading (built-ins only).
3. Default `references`.

So `[[Foo~references]]` placed under `## Contradicts` resolves as `references`. Useful when a section is mostly contradictions but you want one neutral pointer.

## Renames are safe

When you rename a note (via the Flutter app or `memex update --title`), every linker's `[[OldTitle]]`, `[[OldTitle~kind]]`, `[[OldTitle|alias]]`, and `[[OldTitle~kind|alias]]` is rewritten to use the new title — preserving each occurrence's kind and alias. Frontmatter wikilinks get rewritten too. The whole pass is one transaction; if the new title would collide, the rename rejects with `TitleConflict` and nothing is changed.

Pass `--no-rename-links` to opt out.

## Ghost links

If a wikilink points at a title that doesn't exist (e.g., the target was deleted, or you imported markdown from elsewhere), it still records to the `links` table with `to_note_id = NULL`. The right-panel Connections tab marks ghosts with a `GHOST` tag. Click in the Flutter app's autocomplete popover's "+ Create new note titled X" path to materialize a missing target on the spot.

## How to type one in the editor

1. Type `[[` while editing the body. A popover opens.
2. Start typing the title. The list narrows by fuzzy match (recency × match score).
3. ↑ / ↓ to pick, Enter / Tab to accept, Esc to cancel.
4. If your search doesn't match anything, the last item is **"+ Create new note titled X"** — selecting it creates the note immediately and inserts the wikilink.
5. After insertion, a transient chip appears with quick buttons for `references / extends / contradicts / example-of` and a `More…` picker. Click to set the kind. The chip auto-dismisses after 10s, on Esc, or when your cursor leaves the wikilink.

## What the AI does with this

When Claude (or any MCP client) talks to the memex, the link graph is queryable:

- **`get_note(note_id, include_backlinks: true)`** — returns the note plus `links` (outgoing) and `backlinks` (incoming) maps grouped by kind.
- **`neighbors(note_id, depth?, kind?)`** — BFS over the graph. Self-edges excluded. Treats edges as undirected for traversal but preserves direction in the response. Depth clamped at 3.
- **`add_link(from_id, to_id, kind?, label?)`** — agents can extend the graph too. `references` writes into `## Auto-added links`; any other kind writes into frontmatter. Idempotent.

The semantic difference between `extends` and `contradicts` and `example-of` is what lets an AI do qualitatively different things from "search returns chunks." Asking *"what notes contradict this one?"* turns into a single graph query, not a flaky pattern-match.

## Wikilinks on the canvas

Open Memex also has a [visual canvas view](canvas.md). The lines you draw
between nodes on a canvas *are* the wikilinks described in this doc —
drawing a line writes a `[[Target~kind|label]]` token into the source
note, and editing a line via the canvas's edge inspector rewrites that
exact wikilink occurrence in place. Frontmatter-bound wikilinks accept
label edits but not kind changes via the inspector (the kind lives in
the YAML key).

## Documented limitations (v1)

- Wikilinks inside fenced code blocks or inline code are still extracted. They're rare in practice; we'll add code-block exclusion in v2.
- Title matching is case-sensitive. `[[hello]]` does not resolve to a note titled `Hello`.
- The Flutter editor styles wikilinks as plain text inside the `TextField`. Click-to-navigate today happens via the right-panel Connections tab. Styled `TextSpan` rendering + `Stack`-overlay tap routing on `EditableText` is v2 work.
- No transclusion (`![[Title]]`) yet.
- Renaming a note that would collide with another title fails — fix the conflict first.
- Migration from a v2 vault with duplicate titles auto-renames the duplicates as `"<title> (2)"`, `"<title> (3)"`, etc., with each rename logged in `notes_dedup_log`. Above 1,000 collisions the migration aborts and the Flutter app surfaces a triage screen (recovery: `memex update --title` to dedupe manually, then re-open).
- Free-form labels in the kind position fall back to `references` and a `tracing` warning.
