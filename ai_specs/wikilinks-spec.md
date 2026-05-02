<goal>
Add wikilink-based note linking to Open Memex. The user can type `[[Title]]` while writing markdown and immediately link to (or create) another note in their vault. Links are typed via four kinds — `references` (default), `extends`, `contradicts`, `example-of` — surfaced in three input forms (inline `[[Title|kind]]`, curated section headings, YAML frontmatter). The link graph is exposed both in the GUI (autocomplete popover, kind chip, ghost-link rendering, backlinks panel) and to AI agents over MCP (real backlinks, graph traversal, agent-authored links).

**Why it matters:** Search alone treats notes as a flat bag of chunks. A typed link graph encodes the structure of the user's thinking — what extends what, what contradicts what, what stands as an example of what — which qualitatively expands what AI agents can do over the vault: load foundational context, surface contradictions, follow trains of thought, and write back into the graph as they synthesize.

**Outcome:** Within this slice, the user can:
1. Type `[[` and pick or create a target note from a fuzzy-search popover, with the create-on-the-fly path inserted as the last popover item when no title matches exactly.
2. Click any wikilink to navigate to the target — or auto-create-and-navigate when the target is a ghost link (target not yet present).
3. Use a small inline chip after a fresh wikilink to set its kind without leaving the keyboard flow.
4. Group typed links by writing them under curated headings (`## Contradicts`, `## Extends`, etc.) or in YAML frontmatter.
5. See a `## Backlinks` panel under each note, grouped by kind, to follow links back.
6. Have Claude (or any MCP client) call `get_note(include_backlinks=true)`, `neighbors`, and `add_link` against the same vault.
</goal>

<background>
**Project root:** `~/code/open_src/open_memex/`

**Existing architecture (already shipped):**
- `crates/memex-core/` — Rust library: SQLite + WAL + FTS5 + `sqlite-vec` (`vec0`), notes CRUD with optimistic concurrency, chunker, embedder (FakeEmbedder + FastEmbedder), inline indexer, hybrid search via Reciprocal Rank Fusion. Schema currently at version 2.
- `crates/memex-mcp/` — `memex` binary with subcommands `init`, `add`, `update`, `get`, `ls`, `serve`. MCP server (rmcp 1.5) over stdio with three tools: `search`, `get_note`, `create_note`.
- `app/` — Flutter macOS app with vault picker (incl. create-vault dialog), note list sidebar, plain `TextField` markdown editor with debounced save, Riverpod state, sandbox disabled (subprocess + filesystem read), reads vault SQLite directly via `sqlite3` package, writes go through the `memex` CLI subprocess.

**Files to examine before implementing (read, don't guess):**
- `@crates/memex-core/src/schema.rs` — see how v1 → v2 migration is structured.
- `@crates/memex-core/src/indexer.rs` — see `reindex_note`; the new link extraction joins this pipeline.
- `@crates/memex-core/src/notes.rs` — `update_note` (where the title-rename pass hooks in).
- `@crates/memex-core/src/tags.rs` — pattern for simple per-note relation tables (`add_tag`, `tags_for_note`).
- `@crates/memex-core/src/search.rs` — pattern for query construction, RRF, snippet enrichment.
- `@crates/memex-mcp/src/main.rs` — how subcommands are added.
- `@crates/memex-mcp/src/tools.rs` — how MCP tools are registered.
- `@app/lib/src/db.dart` — `VaultDb` read-only access; extend for link queries.
- `@app/lib/src/widgets/note_editor.dart` — the editor; this is where autocomplete, ghost links, and the chip live.
- `@app/lib/src/state/vault_state.dart` — Riverpod providers; backlinks/links providers join here.

**New dependencies expected:**
- Rust: `serde_yaml` (frontmatter parsing), `regex` (link extraction). Both stable, widely used.
- Flutter: none required — popover and inline pill can be built with stock Material widgets. (If a stock Material `MenuAnchor`/`PopupMenu` proves awkward for the inline-text-anchored popover, an `Overlay` + `CompositedTransformTarget` is the canonical Flutter pattern for caret-anchored popovers.)

**Naming + style:**
- Rust: `link_kind` is a `LinkKind` enum (`References`, `Extends`, `Contradicts`, `ExampleOf`); SQL stores lowercase strings (`references`, `extends`, `contradicts`, `example-of`). `LinkSource` enum likewise (`InlineBody`, `InlineSection`, `Frontmatter`, `AutoAdded`).
- Curated section headings are matched **case-insensitively** with whitespace trimmed: `## Contradicts`, `## contradicts`, `##  Contradicts` all count.
- Wikilink syntax: `[[Title]]` or `[[Title|kind]]`. Whitespace inside `[[ ]]` is trimmed before resolution. Pipe is forbidden inside titles (it's the kind separator); enforced at note creation/rename.
</background>

<user_flows>

**Primary flow A — type `[[` to link:**
1. User is editing a note. They type `[[`.
2. A popover appears anchored to the caret. Empty query: shows top recent notes; non-empty: shows fuzzy-matched titles ranked by recency × match score.
3. User keeps typing — popover narrows.
4. User presses ↑/↓ to navigate, Enter to select, Esc to dismiss.
5. Selecting an existing note → editor inserts `]]` to close the wikilink, the popover closes, and the cursor lands after `]]`.
6. A small "references" chip appears next to the just-inserted wikilink for ~4s; clicking it cycles `references → extends → contradicts → example-of` and rewrites the text to `[[Title|kind]]` (or back to `[[Title]]` for `references`).

**Primary flow B — create-on-the-fly:**
1. User types `[[Some Brand New Idea` in the popover.
2. None of the existing notes match exactly. The popover's last item is "**+ Create new note titled** "Some Brand New Idea"".
3. User selects that item.
4. App calls `memex add` to create the note immediately (empty body, default frontmatter, no auto-tag).
5. The new note's title is inserted as `[[Some Brand New Idea]]`. The editor stays in the current note; the new note is now navigable.

**Primary flow C — click a wikilink:**
1. The editor renders wikilinks as styled inline links (different color than prose, no underline by default).
2. Click (or Cmd+click on macOS — TBD during implementation, default to bare click for v1) a wikilink whose target exists → editor switches to that note (the same path as clicking a sidebar item).
3. Click a ghost wikilink (target not in the vault) → app silently calls `memex add` to create the note, then switches to it. Acts the same as create-on-the-fly but post-hoc.

**Primary flow D — section-based grouping:**
1. User writes `## Contradicts\n\n[[Foo]]\n[[Bar]]`.
2. On save → reindex → both `Foo` and `Bar` links are recorded with `kind=contradicts`, `source=inline_section`.
3. The wikilink text on disk remains `[[Foo]]` — no `|kind` suffix needed.

**Primary flow E — frontmatter typed link:**
1. User writes YAML frontmatter:
   ```yaml
   ---
   extends: [[Local-first principles]]
   contradicts:
     - [[Server-as-source-of-truth]]
   ---
   ```
2. On save → reindex parses the YAML → records each wikilink with the matching kind and `source=frontmatter`.
3. Frontmatter wikilinks are also part of the link graph; they show up in `neighbors()` and `## Backlinks`.

**Primary flow F — backlinks panel:**
1. User opens any note in the editor.
2. Below the editor body, a `## Backlinks` panel lists all notes linking IN to this one, grouped by kind (`Contradicted by`, `Extended by`, `Examples`, `References`).
3. Clicking a backlink switches to that note.

**Primary flow G — agent (MCP) flow:**
1. Claude calls `get_note(note_id, include_backlinks: true)`.
2. Response includes `links` (outgoing) and `backlinks` (incoming) grouped by kind.
3. Claude calls `neighbors(note_id, depth: 1)` to traverse the local graph; returns adjacent notes + the edges.
4. Claude calls `add_link(from_id, to_id, kind: "contradicts")` while synthesizing — server inserts a wikilink in the right place per the kind→destination rules below and reindexes.

**Alternative flows:**
- *Renaming a note*: `memex update --title "New Title"` performs a transactional rename pass — every `[[Old Title]]` and `[[Old Title|kind]]` in any note's body or frontmatter becomes the new title. Opt-out: `--no-rename-links`. The new-title collision case (a different note already has `New Title`) rejects the rename with a `TitleConflict` error.
- *Importing markdown with wikilinks but no matching notes*: links are recorded with `to_note_id = NULL` (ghost). They render as ghost links in the editor; clicking creates the target.
- *Editor uses `[[` literally inside a code block / inline code*: extractor still records the link by default (we are not parsing markdown semantics for v1). Code-block exclusion is a v2 nicety.
- *Frontmatter is malformed YAML*: the indexer logs the parse error, treats frontmatter as empty for indexing, and the editor shows a small "frontmatter parse error" badge near the top. Body indexing still proceeds.

**Error / recovery flows:**
- Title-rename collision → operation aborts with `TitleConflict { existing_id, attempted_title }`. No note is modified. CLI exits non-zero, MCP returns structured error.
- `add_link` from a non-existent `from_id` or `to_id` → structured `NotFound` error; nothing inserted.
- Popover create-on-the-fly fails (e.g., `memex` binary not found, init fails) → snackbar with the error; no wikilink inserted; user's typed text remains so they can try again.
- Concurrent vault writes (app + MCP touching the same note) → optimistic concurrency on `update_note` wins; the loser sees `VersionConflict` and surfaces the existing reload prompt. Link-graph stays consistent because each write reindexes that note's outgoing links atomically.
</user_flows>

<requirements>

**Functional — schema and core (`memex-core`):**

1. Apply schema migration v2 → v3:
   - Add `UNIQUE` constraint to `notes.title`. The migration must check for pre-existing duplicates and rename conflicts deterministically as `"<title> (2)"`, `"<title> (3)"`, … with a one-line warning per renamed note logged via `tracing`. Emit a side-table `notes_dedup_log(old_title, new_title, note_id)` so the GUI can later surface "we renamed N notes during upgrade." Idempotent: re-running the migration on an already-deduped DB is a no-op.
   - Create `links(id TEXT PRIMARY KEY, from_note_id TEXT NOT NULL REFERENCES notes(id) ON DELETE CASCADE, to_note_id TEXT NULL REFERENCES notes(id) ON DELETE SET NULL, link_text TEXT NOT NULL, link_kind TEXT NOT NULL, label TEXT NULL, position INTEGER NOT NULL, source TEXT NOT NULL)`. `link_kind` ∈ {`references`, `extends`, `contradicts`, `example-of`}. `source` ∈ {`inline_body`, `inline_section`, `frontmatter`, `auto_added`}.
   - Create indexes: `(from_note_id)`, `(to_note_id)`, `(link_kind, to_note_id)`.
2. Define a `LinkKind` Rust enum (`References`, `Extends`, `Contradicts`, `ExampleOf`) with `as_str` / `from_str` for SQL round-tripping. Same for `LinkSource`. Bind both via `rusqlite::ToSql` / `FromSql`.
3. Add a `links.rs` module with: `add_link`, `remove_link`, `links_for_note(note_id, direction)`, `replace_links_for_note(note_id, links)`. The replace fn is what the indexer uses (delete + insert in one transaction).
4. Implement a `link_extractor` module that, given a note's full markdown (frontmatter + body), returns a vector of `ExtractedLink { link_text, kind, label?, position, source }` records.
   - Wikilink regex: matches `[[<title>]]` or `[[<title>|<kind>]]`. Title is non-empty after trim, contains no `]`, no newline. Kind, if present, must match the four-kind whitelist (case-insensitive, hyphen or space tolerant: `example-of`, `example of`, `Example Of` all map to `ExampleOf`). Unknown kinds fall back to `References` and the unknown literal is logged.
   - Frontmatter parse: YAML at top of file delimited by `---` lines. Keys `references`, `extends`, `contradicts`, `example-of` (kebab or underscore: `example_of` also accepted). Values are scalar `[[Title]]`, list of `[[Title]]`, or list of bare strings (treated as titles).
   - Section grouping: when a wikilink in the body sits under a curated `##` heading (the closest preceding heading at depth 2), it inherits the kind of that heading. Curated headings (case-insensitive, trimmed): "Contradicts" → `Contradicts`, "Extends" / "Builds on" / "Builds-on" → `Extends`, "Example of" / "Examples" → `ExampleOf`, "See also" / "References" → `References`, "Open questions" → no implicit kind (its presence is captured separately as a bool on the note for AI surfacing — see #6).
   - Precedence: explicit `[[Title|kind]]` > section-based > frontmatter context > default `References`.
5. Extend `indexer::reindex_note` to also rebuild the row's outgoing links via `replace_links_for_note`. Resolution: for each `link_text`, look up the matching `notes.title` and set `to_note_id` (or `NULL` if no match — ghost link). Same single transaction as the existing chunk/FTS/vec rewrite.
6. Add a derived flag `notes.has_open_questions BOOLEAN NOT NULL DEFAULT 0` (migration-time) computed by the indexer when the body contains a `## Open questions` heading. Lets agents query "show me notes with open questions" cheaply.
7. Implement `notes::update_note` enhancement: when the title changes, perform a transactional rename pass that rewrites every `[[OldTitle]]` and `[[OldTitle|kind]]` in every note's `content_md` (including frontmatter strings) to the new title, then reindexes each touched note. New parameter: `RenameOptions { rename_links: bool }` (default true). The new title is validated against the unique constraint **before** doing any rewrites — collision returns `MemexError::TitleConflict { existing_id, attempted_title }` and no change is made.
8. Implement a `graph::neighbors(conn, note_id, depth, kind?)` function: BFS over `links`, depth-capped (max 3), with optional kind filter. Returns `Vec<NeighborHit { note_id, title, distance, edges: Vec<EdgeMeta> }>`.

**Functional — `memex` CLI:**

9. Add `memex links --vault <p> --note-id <id> [--in|--out|--both] [--kind <k>]` — prints links for a note as a tree, grouped by kind. Default direction: `--both`.
10. Add `memex add-link --vault <p> --from <id> --to <id> [--kind <k>] [--label <s>]`. Default kind: `references`. Body markdown is updated according to the kind→destination rule (see #14 below) and the note is reindexed in one transaction.
11. Existing `memex update --vault <p> --note-id <id> --expected-version <v> [--title ...]` accepts a new `--no-rename-links` flag.
12. `memex get` JSON output gains an optional `--include-links` flag that adds `links: [...]` and `backlinks: [...]` arrays to the response.

**Functional — MCP server (`memex-mcp`):**

13. `get_note` tool param `include_backlinks: bool` (default false). When true, the response payload gains `links: { references: [...], extends: [...], contradicts: [...], example_of: [...] }` and `backlinks` with the same shape. Each entry: `{ note_id, title, link_id, label?, source }`.
14. New tool `neighbors(note_id: string, depth?: int = 1, kind?: string)`. Returns `{ vault_id, root_note_id, depth, results: [{ note_id, title, distance, edges: [{ from_id, to_id, kind, label? }] }] }`. Depth clamped server-side to `[1, 3]`.
15. New tool `add_link(from_id: string, to_id: string, kind?: string, label?: string)`. Default kind: `references`.
   - Destination rule:
     - If `kind` is `references` (or omitted), append a single line `[[<Target Title>]]` to (or after) a `## Auto-added links` section at the bottom of the source note (creating the section if absent).
     - If `kind` is one of `extends`/`contradicts`/`example-of`, write into YAML frontmatter under the corresponding key (creating frontmatter if absent). Idempotent: a duplicate add is a no-op (returns the existing link id).
   - Returns `{ vault_id, link_id, from_id, to_id, kind, source: "auto_added"|"frontmatter", note_version: int }`.
16. All three new/changed tools include the standard `vault_id` + structured-error handling already used by `search`/`create_note`.

**Functional — Flutter app (`app/`):**

17. Wikilink autocomplete:
    - Detected by a `WikilinkAutocompleteController` watching `TextEditingController` changes; opens a popover anchored to the caret position when an unclosed `[[` is observed before the cursor and there is no `]]` between `[[` and the cursor.
    - Popover contents: 0..N matched note titles (max 8 visible, scroll for more), ranked by simple fuzzy score × recency; followed by a "+ Create new note titled `<query>`" item iff `<query>` does not exactly match any existing title.
    - Keyboard: `↑/↓` move selection, `Enter`/`Tab` accept, `Esc` dismiss, typing updates the query, backspacing past `[[` dismisses.
    - Accept-existing inserts `<Title>]]` after the existing `[[`, places the cursor right after `]]`, closes the popover, schedules the inline kind chip.
    - Accept-create calls `memex add --title "<query>" --vault <vault>` via `MemexCli`. On success, inserts `<query>]]` and the popover closes; on failure, snackbar.
18. Ghost-link click: if the user clicks a wikilink whose `to_note_id IS NULL` (resolved at render time from the live `links` table), call `memex add` to create the note, then navigate via the existing `selectedNoteIdProvider`.
19. Inline kind chip: appears next to the just-inserted wikilink (overlay positioned at the closing `]]`). Default label "references". Click cycles through the four kinds; rewriting the body text to `[[Title|kind]]` (or stripping the suffix back to `[[Title]]` for `references`). Auto-dismiss on next keystroke, focus loss, or 4s timeout (whichever is sooner).
20. Wikilink rendering inside the editor: implemented via `TextField` in normal mode and a separate "rendered overlay" pass that detects wikilink ranges and paints a `Container` with click handler over each match. (Fallback if rich text inside the editable body is too involved: render wikilinks as plain text with a subtle background highlight + a separate, simpler "Links" sub-panel that lists them clickably. Behavior to be locked in during Phase 4 implementation.)
21. `## Backlinks` panel: a fixed-height panel below the editor body. Reads `links_in(note_id)` from `VaultDb`. Groups by kind, headers per group, click-to-navigate. Empty state: "No backlinks yet."
22. Refresh: `vaultRevisionProvider` already exists; bump it after every write so the backlinks panel and the wikilink resolver both reread.
23. New Riverpod providers: `linksOutProvider(noteId)`, `linksInProvider(noteId)`, `wikilinkAutocompleteProvider`. All three hydrate from `VaultDb`; writes go through `MemexCli`.

**Error Handling:**

24. Title-conflict on creation, rename, or migration-rename: structured `TitleConflict` error end-to-end. Migration is the only place where conflicts are auto-resolved (with logged renames); user-driven conflicts always reject.
25. `add_link` with a non-existent `from_id` / `to_id`: `NotFound` error; nothing is mutated.
26. `add_link` for a link that already exists (same `from_id`, `to_id`, `kind`): no-op; returns the existing link id with `was_existing: true`.
27. Frontmatter YAML parse failure: indexer logs the error, treats frontmatter as empty for that pass, and sets `notes.frontmatter_parse_error` (boolean column added in v3 migration). Body indexing continues. Editor surfaces a small warning chip.
28. `[[]]` and `[[ ]]` and other zero-length wikilinks: extractor skips silently. No error, no link.
29. `[[Title|made-up-kind]]` (unknown kind): extractor records the link as `kind=References`, logs the unknown literal, includes it in the optional `label` field for round-trip preservation.
30. Title-rename pass partial failure: the entire rename is one transaction; if any rewrite fails for any reason (e.g. SQLite busy), the whole rename rolls back, including the `notes.title` change.

**Edge Cases:**

31. Self-link (`[[This Title]]` in the same note): allowed but ignored for backlink/neighbor purposes — recorded with `from_note_id == to_note_id` and a `source` of whatever applies; UI hides them from the backlinks panel.
32. Multiple wikilinks to the same target in the same note: each occurrence is a separate row in `links` (distinguished by `position`). Backlinks panel deduplicates per source-note; `neighbors` returns one edge per source-note.
33. Wikilinks inside fenced code blocks / inline code: extracted as normal in v1 (we don't parse markdown semantics yet). Documented limitation.
34. Wikilinks containing characters with case differences (`[[hello]]` vs note `Hello`): titles are matched **case-sensitively** because titles themselves are case-sensitive in v1. We accept this as a minor papercut documented in the README; future v2 may add case-folded resolution.
35. A note whose title contains `|` (the kind separator): rejected at create / rename time with `TitleInvalid` and a helpful message. Migration auto-renames such notes by replacing `|` with `-`.
36. Frontmatter list with mixed bare strings and `[[...]]`: both accepted, both treated as titles for resolution.
37. Long notes (>50k chars): extractor must not be quadratic; use a single regex pass + linear scan over headings.
38. Concurrent rename + indexing of the same note (very unlikely but possible if Claude writes mid-rename): SQLite WAL serialization + the rename transaction holding the write lock guarantees consistency. Loser retries via existing `busy_timeout`.

**Validation:**

39. Pre-rename validation: target new title is non-empty after trim, ≤ 200 characters, contains no `|`, no newline, no leading/trailing whitespace.
40. `add_link` arg validation: `from_id` and `to_id` are valid ULIDs; `kind` if provided is in the whitelist; `label` ≤ 200 characters.
41. Wikilink popover query: trimmed; empty query shows top recent notes (≤ 8); query length capped at 200 chars before being sent through the matcher.
</requirements>

<boundaries>

**Edge cases:**
- *Vault upgraded from v2 with duplicate titles*: deterministic auto-rename with logging (see requirement 1). The dedup log is exposed via a one-time banner in the GUI on first launch after upgrade.
- *User typing `[[` immediately followed by another `[`*: popover should not open until at least one non-`[` character is typed after `[[`. Backspace closes popover.
- *Pasting markdown that contains `[[Title]]` references*: indexer extracts on next save like normal.
- *A note linked from many others is deleted*: `to_note_id` is set to `NULL` via `ON DELETE SET NULL`. Backlinks turn into ghost links in the editor and disappear from the backlinks panel. Reindexing the linking notes will keep them as ghost text references.

**Error scenarios:**
- *`memex` binary missing while autocomplete is active*: popover is replaced with an error state ("memex binary not found — locate it in settings"); no link is inserted.
- *SQLite busy during rename*: existing `busy_timeout` (5s) handles transient cases; persistent failure surfaces the underlying error.
- *Frontmatter contains `extends: [Foo]` (bare string, unquoted)*: treated as title `Foo` (the bare-string-as-title rule).
- *`add_link` source note has more than one matching kind section*: append to the **last** matching one (newest content first, intuitive for an append).

**Limits:**
- Per-note wikilink count: soft-capped at 1,000 outgoing links; beyond that the indexer logs a warning and only the first 1,000 are recorded. Realistic notes are well under 50.
- Backlink panel: shows up to 200 incoming links across all kinds; "Show all" button reveals more.
- `neighbors()` depth: clamped to 1..3 (server-side enforcement; agents can't accidentally explode the graph).
- Auto-dedup migration: hard-bails if there are >1,000 collisions to dedup (vault is misshapen; surface a clear error and abort).

</boundaries>

<implementation>

**Files to create or modify:**

*Rust core (`crates/memex-core/`):*
- `src/schema.rs` — add v3 migration: unique title, `links` table, `notes_dedup_log`, `notes.has_open_questions`, `notes.frontmatter_parse_error`. Bump `APP_SCHEMA_VERSION` to 3.
- `src/links.rs` (new) — `LinkKind`, `LinkSource`, `Link`, `add_link`, `remove_link`, `links_out_for_note`, `links_in_for_note`, `replace_links_for_note`.
- `src/link_extractor.rs` (new) — pure parser: input markdown → `Vec<ExtractedLink>`. Includes the YAML frontmatter parser, regex-based body scan, heading-based section context, and precedence rules.
- `src/graph.rs` (new) — `neighbors`, `degree`. Pure functions over `&Connection`.
- `src/indexer.rs` — extend `reindex_note` to call `link_extractor` then `replace_links_for_note`; also set `has_open_questions` and `frontmatter_parse_error`.
- `src/notes.rs` — extend `update_note` with `RenameOptions`; on title change with rename_links=true, run rewrite pass over the body and frontmatter of every note that links to the old title (use a `links` query, not a full table scan). Reject on collision before any rewrite.
- `src/lib.rs` — export new modules.
- `tests/links_extraction.rs` (new) — chunker-style unit tests for the extractor.
- `tests/links_integration.rs` (new) — vault-level integration: create + rename + ghost links + frontmatter + sections.
- `tests/migration_v3.rs` (new) — dedup of pre-existing duplicate titles.

*MCP / CLI (`crates/memex-mcp/`):*
- `src/main.rs` — add `Links`, `AddLink` subcommands; thread `--no-rename-links` through `Update`.
- `src/tools.rs` — add `neighbors` and `add_link` tools; extend `get_note` to honor `include_backlinks`.
- `tests/tool_smoke.rs` — extend with link-aware tests (3-4 new cases).

*Flutter app (`app/`):*
- `lib/src/db.dart` — add `linksOutForNote(id)` and `linksInForNote(id)` reading from the new table.
- `lib/src/memex_cli.dart` — add `addLink(from, to, kind?, label?)`; thread `noRenameLinks` through `updateNote`.
- `lib/src/state/vault_state.dart` — add `linksOutProvider`, `linksInProvider`, `wikilinkAutocompleteProvider`.
- `lib/src/widgets/note_editor.dart` — wire the autocomplete controller, ghost-link click handler, inline kind chip overlay, and the backlinks panel under the editor body.
- `lib/src/widgets/wikilink_autocomplete.dart` (new) — the popover widget + controller.
- `lib/src/widgets/backlinks_panel.dart` (new).
- `lib/src/widgets/kind_chip.dart` (new).
- `test/widget_test.dart` — new tests for the autocomplete popover and backlinks panel.

**Patterns to follow:**
- Mirror the `tags.rs` shape for `links.rs` (small, focused module).
- Mirror the `chunker.rs` test layout for the link extractor (pure-function unit tests with clear input fixtures).
- Mirror the existing transactional pattern in `indexer::reindex_note` for the new link-rewrite step.
- The Flutter app's existing "writes via subprocess, reads via `VaultDb`" split applies to links unchanged.

**What to avoid and why:**
- Don't add a separate `link_kinds` lookup table — four enum values, hard-coded SQL strings, validated at the Rust boundary. A lookup table is overkill and costs joins.
- Don't precompute backlinks into a separate cache — a query against `links WHERE to_note_id = ?` with an index is fast enough (<1ms for vaults of 10k notes).
- Don't try to parse all markdown semantics for the extractor (no AST, no fenced-code-block exclusion in v1) — regex + heading scan is enough and orders of magnitude simpler. Documented limitation.
- Don't write a recursive-descent YAML parser — use `serde_yaml`. Adding a stable, well-known dep is preferable to maintaining a fragile parser.
- Don't introduce a new state-management pattern for the popover — Riverpod + a controller is the same shape we already use.
- Don't try to do graph PageRank in v1 — it was discussed and explicitly deferred.

</implementation>

<stages>

**Phase 1 — schema + extractor + indexer (Rust core, no UI changes).**
- Verify: `cargo test -p memex-core` green, including new extractor unit tests and links-integration tests. `cargo clippy --workspace --all-targets -- -D warnings` clean.
- After this phase, calling `memex update --vault ... --note-id ...` against a note containing `[[Title]]` results in correctly populated `links` rows. Nothing else has changed.

**Phase 2 — title rename pass + CLI links/add-link.**
- Verify: integration tests assert that `update_note` with a new title rewrites all linking notes' bodies and reindexes them transactionally. Collision rejects without changes. `memex links --note-id ...` prints the expected tree. `memex add-link` inserts at the right destination per kind.

**Phase 3 — MCP additions (`get_note(include_backlinks)`, `neighbors`, `add_link`).**
- Verify: `tool_smoke.rs` integration tests exercise all three. Manual: in Claude Desktop, ask "what links to this note?" and "find any contradictions" against a seeded vault.

**Phase 4 — Flutter editor: autocomplete + ghost click + chip + backlinks panel.**
- Verify: widget tests for the popover (typing `[[` opens it; typing narrows; selecting "+ Create" calls the CLI; ghost link click creates the note). Robot-driven journey: create note → type `[[` → pick a target → close popover → click the wikilink → editor switches notes → backlinks panel shows the source note. All `flutter analyze` + `flutter test` green.

**Phase 5 — polish + docs.**
- Verify: README updated, `docs/wikilinks.md` new (covers the four kinds, frontmatter, sections). `docs/claude-desktop-setup.md` mentions the new tools. Acceptance test in `docs/acceptance-test.md` extended with three link-aware questions for Claude.

Each phase ends with: `cargo test --workspace` && `cargo clippy --workspace --all-targets -- -D warnings` && (Phase 4+) `flutter analyze` && `flutter test`.

</stages>

<validation>

**Test layering:**

*Rust core (`memex-core`):*
- **Unit tests** for the link extractor (pure function): empty input, body wikilinks, typed wikilinks, section-grouped wikilinks, frontmatter wikilinks, mixed-kind precedence (explicit > section > frontmatter > default), unknown kind handling, malformed frontmatter, self-links, duplicate links, long notes (linear-time check via input size assertion).
- **Integration tests** (vault on `tempfile::TempDir`):
  - Create note with `[[Foo]]` → `links` row written; `to_note_id` is NULL; `source = inline_body`; `kind = references`.
  - Create the target note `Foo` → reindex either side updates `to_note_id`.
  - Rename `Foo` → `Bar` rewrites every `[[Foo]]` to `[[Bar]]` in linking notes' bodies and frontmatter; collision case rejects before any change is made.
  - `add_link(from, to, kind=contradicts)` inserts into frontmatter; `add_link(from, to)` (no kind) inserts into `## Auto-added links`.
  - `neighbors(root, depth=2)` returns expected BFS over a hand-built fixture.
  - Migration v2→v3 with pre-seeded duplicate titles auto-renames and logs.

*MCP (`memex-mcp`):*
- **Smoke tests** that drive `Memex` directly (no MCP transport):
  - `get_note(id, include_backlinks=true)` shape.
  - `neighbors(id, depth=2)` returns expected edges; `depth=99` is clamped.
  - `add_link` happy path + idempotent re-call returns `was_existing=true` + non-existent ids return structured errors.

*Flutter app:*
- **Widget tests** (deterministic, fake `MemexCli` + an in-memory `VaultDb` stub):
  - Typing `[[F` in the editor opens the popover; the popover lists matching titles.
  - Typing a non-matching string shows "+ Create" as the last item; selecting it calls the fake CLI's `addNote` and closes the popover.
  - Backlinks panel renders incoming links grouped by kind from a seeded fixture; click navigates by setting `selectedNoteIdProvider`.
  - Inline kind chip cycles `references → extends → contradicts → example-of → references` and rewrites the document text accordingly.
- **Robot-driven journey test**: open temp vault → create note "Source" → type `[[Targ` → select "+ Create new note titled 'Targ'" → assert "Targ" exists in the sidebar → click the wikilink → editor switches to "Targ" → backlinks panel shows "Source" under References. Stable selectors: `Key('wikilink-popover')`, `Key('wikilink-popover-item-{title}')`, `Key('wikilink-popover-create')`, `Key('wikilink-{noteId}')`, `Key('backlinks-panel')`, `Key('backlink-item-{noteId}')`, `Key('kind-chip')`.

**TDD expectations:**

- The link extractor and graph-traversal logic are pure functions — drive each behavior **test-first**, RED → GREEN → REFACTOR per slice. Order: happy path → boundary cases (empty, very long, malformed) → error/edge cases (unknown kinds, conflicts).
- Test seams:
  - Extractor accepts plain `&str`; no I/O. Easy to test.
  - Indexer's link-rewrite step is exercised through the existing `reindex_note` integration tests (real SQLite temp vault). Don't mock SQLite.
  - Title-rename's transactional rewrite uses a `Clock` parameter only if we need timestamp determinism in tests; otherwise just assert post-state.
  - `MemexCli` exposes a constructor-injected interface in the Flutter app so widget tests can swap a fake. Add a minimal `FakeMemexCli` in `test/` that records calls and returns canned ULIDs.
- Flutter widget rendering tests are written after the widget shape settles; pure logic in Dart (controllers, state mappings) is TDD'd.

**Mocking policy:**
- Prefer fakes over mock frameworks.
- Mock only true external boundaries: `MemexCli` in widget tests; the `memex` subprocess in integration tests that don't need to validate end-to-end binary behavior.
- Do **not** mock SQLite or `VaultDb` — use real temp SQLite files. The behaviors of FTS5, `vec0`, the indexer, and WAL are part of what we are validating.

**Baseline coverage outcomes required:**
- All new Rust modules (`links.rs`, `link_extractor.rs`, `graph.rs`) have unit tests for their public functions.
- Every MCP tool method has at least one happy-path and one error-path test.
- Migration v2→v3 has a dedicated regression test (dedup of duplicate titles, idempotent re-run).
- Title-rename path has happy + collision + opt-out (`--no-rename-links`) tests.
- One Flutter robot-driven journey test passes in CI (`flutter test`).

**Acceptance test (manual):**
Extend `docs/acceptance-test.md` with:
1. Type `[[` inside a note; the popover appears and lists existing titles.
2. Type a brand-new title; select "+ Create"; the new note exists and is linked.
3. Use a `## Contradicts` heading and put `[[Some Note]]` under it; backlinks on the target show "Contradicted by" the source.
4. Add YAML frontmatter `extends: [[Some Note]]`; backlinks show "Extended by" the source.
5. Rename a note; every `[[Old Title]]` rewrites to `[[New Title]]`.
6. Ask Claude (via MCP) "what notes contradict this one?" — Claude calls `get_note(include_backlinks=true)` and answers grounded.
7. Ask Claude "create a contradicts link from this note to that other one" — Claude calls `add_link`; the linking note's frontmatter gets the new entry; `## Backlinks` panel updates.
</validation>

<done_when>
1. `cargo build --workspace --release` succeeds.
2. `cargo test --workspace` passes (all new tests green).
3. `cargo clippy --workspace --all-targets -- -D warnings` clean.
4. `flutter analyze` clean; `flutter test` passes (including the new robot journey).
5. `flutter build macos --debug` produces a runnable app.
6. Manually: typing `[[` in the editor opens the popover; selecting an existing match inserts a wikilink that the chip can re-kind; selecting "+ Create" creates the note and inserts the wikilink in one step.
7. Manually: clicking a ghost wikilink (e.g., one written by Claude into a note before the target existed) creates the target note and navigates to it.
8. Manually: writing `## Contradicts\n[[Foo]]` and saving causes Foo's `## Backlinks` panel to show the source under "Contradicted by".
9. Manually: writing YAML frontmatter `extends: [[Foo]]` and saving yields the same backlinks behavior under "Extended by".
10. Manually: running `memex update --note-id <id> --title "New" --expected-version <v>` rewrites every linking note's `[[Old]]` to `[[New]]` in body and frontmatter, transactionally.
11. Manually: in Claude Desktop, `get_note(id, include_backlinks=true)`, `neighbors(id, 2)`, and `add_link(from, to, kind=contradicts)` all return structured payloads consistent with this spec.
12. Migration v2 → v3 runs cleanly on a vault with pre-existing duplicate titles, deduping deterministically and logging the renames.
13. README, `docs/wikilinks.md`, `docs/claude-desktop-setup.md`, and `docs/acceptance-test.md` updated.
</done_when>
