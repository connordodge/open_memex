# Wikilinks — Implementation Plan

## Overview

Add `[[Title~kind|alias]]` wikilinks (built-in 4 + user-defined kinds) end-to-end: schema → extractor → indexer → CLI → MCP → Flutter editor with keystroke-anchored autocomplete. Phase 1 = thin vertical slice proving link extraction populates a queryable graph on every save.

**Spec**: `ai_specs/wikilinks-spec.md` (read for full requirements)

## Context

- **Layout**: Cargo workspace + Flutter app monorepo. `memex-core` is the Rust library, `memex-mcp` the CLI/MCP binary, `app/` the Flutter macOS app.
- **Rust state**: free-function modules; `tags.rs` is the canonical small-module mirror for `links.rs`. Schema migrations are SQL `Vx` consts in `schema.rs`; bump `APP_SCHEMA_VERSION` and add a `current < N` branch.
- **Flutter state**: Riverpod 2.5. Providers in `app/lib/src/state/`. Editor in `widgets/note_editor.dart` uses a stateful `EditorController` (`StateNotifier`) + plain `TextField` with debounced save. **All writes go through `MemexCli` subprocess**, reads via `VaultDb` (read-only SQLite).
- **Key syntax decisions baked into the plan**:
  - `[[Title~kind|alias]]` — `~` separates kind (preserves `^` for future transclusion); `|` separates display alias (Obsidian-compat).
  - Kinds normalized to `^[a-z][a-z0-9-]*$` length ≤ 64. Built-in 4 (`references`, `extends`, `contradicts`, `example-of`) keep curated-heading + frontmatter shortcuts; user-defined kinds are first-class for storage and `neighbors()`.
  - Frontmatter: only `[[Title]]` form accepted (bare strings ignored).
  - Autocomplete trigger: keystroke-driven (not caret-driven) — won't reopen on edit-existing.
  - Bare click navigates wikilinks. Backlinks panel pinned below editor scroll region with collapse toggle.
- **Existing seams** (verified):
  - Indexer: `indexer::reindex_note(conn, id, content_md, embedder)` rewrites chunks/FTS/vec in one transaction — extend with link rewrite in same tx.
  - Optimistic concurrency: `notes::update_note(expected_version)` returns `MemexError::VersionConflict`. Title-rename pass hooks here.
  - MCP placeholder: `tools::GetNoteParams.include_backlinks` already declared at `tools.rs:75` with `#[allow(dead_code)]` — wire up.
- **Stable widget keys** already in use: `Key('editor-content')`, `Key('editor-title')`, `Key('note-list-item-{id}')`, `Key('vault-switcher')`, `Key('save-indicator')`. New keys for popover/chip/backlinks listed in Phase 4.
- **Reference files**: `crates/memex-core/src/{schema.rs, tags.rs, indexer.rs, notes.rs, error.rs}`, `crates/memex-mcp/src/{main.rs, tools.rs}`, `app/lib/src/{db.dart, memex_cli.dart, widgets/note_editor.dart, state/vault_state.dart}`.
- **Pinned new deps**: `serde_yaml = "0.9"`, `regex = "1"` in `[workspace.dependencies]`.
- **Verify command per phase**: `cargo test --workspace && cargo clippy --workspace --all-targets -- -D warnings`; Flutter phases also `(cd app && flutter analyze && flutter test)`.
- **Assumptions / gaps**:
  - In-`TextField` wikilink rendering uses custom `TextEditingController.buildTextSpan` for styling + a `Stack`ed transparent `GestureDetector` over the editor for tap routing (`RenderEditable.getPositionForPoint`). If the tap-overlay proves too fragile during Phase 4 first widget test, fall back to "styled text only + separate Links sub-panel" — documented in spec req 20.
  - Caret-anchored popover: `Overlay` + `LayerLink` + `CompositedTransformFollower` + `RenderEditable.getLocalRectForCaret`. Stock `RawAutocomplete` / `flutter_typeahead` don't fit keystroke-driven mid-text triggers.
  - Performance: regex compiled once (`static`), trigger detection scans `text[caret-64..caret]`, span rebuild debounced 120ms with `text.hashCode` cache.
- **Research provenance**: deep codebase + Flutter-patterns research from the prior `/act-workflow-plan` run; codebase unchanged since.

## Plan

### Phase 1: Schema v3 + link extractor + indexer wiring (Rust core only)

- **Status (2026-05-03)**: complete. 28 unit tests + 9 links integration tests + 3 migration v3 tests pass. cargo clippy --workspace --all-targets -- -D warnings clean. cargo test --workspace green (51 total).
- **Goal**: `memex update` against a note with `[[Title~kind]]` populates `links` rows correctly. End-to-end through the existing CLI; no UI changes yet.
- [x] Root `Cargo.toml` — add `serde_yaml = "0.9"` and `regex = "1"` to `[workspace.dependencies]`; add to `crates/memex-core/Cargo.toml` deps.
- [x] `crates/memex-core/src/error.rs` — add variants: `TitleConflict { existing_id, attempted_title }`, `TitleInvalid(String)`, `TooManyDedupCollisions { count }`, `InvalidLinkKind(String)`.
- [x] `crates/memex-core/src/schema.rs` — bump `APP_SCHEMA_VERSION = 3`; add `V3: &str` const + `current < 3` branch in `apply`. v3 contents: pre-flight count of duplicate-title groups, abort with `TooManyDedupCollisions` if >1,000; otherwise `UNIQUE` on `notes.title` after deterministic dedup `Foo (2)`/`Foo (3)`; create `links` table with CHECK constraints (`link_kind GLOB '[a-z][a-z0-9-]*'`, `length(link_kind) <= 64`, `source IN (...)`) and `UNIQUE (from_note_id, position)`; create indexes; create `notes_dedup_log(note_id PK, old_title, new_title, migrated_at)`; add `notes.has_open_questions BOOLEAN NOT NULL DEFAULT 0` and `notes.frontmatter_parse_error BOOLEAN NOT NULL DEFAULT 0`.
- [x] `crates/memex-core/src/links.rs` (new) — mirror `tags.rs` shape. `LinkKind` newtype wrapping a normalized `String` (`new(s: &str) -> Result<Self>` validates regex + length; `built_in_*()` constants; `is_built_in(&self) -> bool`). `LinkSource` enum (`InlineBody`, `InlineSection`, `Frontmatter`, `AutoAdded`) with `as_str`/`from_str`. `Link` struct. Free fns: `replace_links_for_note`, `links_out_for_note`, `links_in_for_note(note_id, kind?)`. `rusqlite::ToSql`/`FromSql` impls for both types.
- [x] `crates/memex-core/src/link_extractor.rs` (new) — pure function `extract(content_md: &str) -> ExtractedLinks { body, frontmatter, has_open_questions, frontmatter_parse_error }`. Compiled-once regex `\[\[([^\[\]\n~|]+)(?:~([^\[\]\n|]+))?(?:\|([^\[\]\n]+))?\]\]`. Heading-scope tracker for `inline_section` grouping (curated headings, case-insensitive, trimmed). YAML frontmatter via `serde_yaml`; built-in keys + arbitrary kebab-case keys both accepted; **only `[[Title]]` form** as values — bare strings ignored. Position = byte offset into full `content_md`. Invalid kinds → fallback to `references` + `tracing::warn!`.
- [x] `crates/memex-core/src/indexer.rs` — extend `reindex_note`: after chunks/FTS/vec writes, call `link_extractor::extract`, `replace_links_for_note`, and `UPDATE notes SET has_open_questions=?, frontmatter_parse_error=? WHERE id=?`. Same single transaction. Resolution: `SELECT id FROM notes WHERE title = ?` for each link's `link_text`; `to_note_id` is `NULL` when unmatched (ghost).
- [x] `crates/memex-core/src/lib.rs` — re-export `links`, `link_extractor`.
- [x] TDD: extractor — empty input → `ExtractedLinks::default()`.
- [x] TDD: extractor — `[[Foo]]` → kind=`references`, source=`InlineBody`, position is byte offset.
- [x] TDD: extractor — `[[Foo~extends]]` → kind=`extends`.
- [x] TDD: extractor — `[[Foo~inspired-by]]` → kind=`inspired-by` (user-defined, normalized).
- [x] TDD: extractor — `[[Foo|My Foo]]` → kind=`references`, label=`"My Foo"`.
- [x] TDD: extractor — `[[Foo~extends|alias]]` → kind=`extends`, label=`"alias"`.
- [x] TDD: extractor — invalid kind `[[Foo~Made_Up]]` → fallback `references`, warning logged.
- [x] TDD: extractor — `## Contradicts` heading → wikilinks under it inherit `contradicts`, source=`InlineSection`.
- [x] TDD: extractor — `[[Foo~references]]` under `## Contradicts` → explicit kind wins (`references`).
- [x] TDD: extractor — frontmatter `extends: [[Foo]]` → kind=`extends`, source=`Frontmatter`.
- [x] TDD: extractor — frontmatter user-defined key `inspired-by: - [[Foo]]` → kind=`inspired-by`.
- [x] TDD: extractor — frontmatter `extends: Foo` (bare string) → ignored, no link recorded.
- [x] TDD: extractor — malformed YAML → `frontmatter_parse_error=true`, body still parsed.
- [x] TDD: extractor — `[[]]` and `[[ ]]` → silently skipped.
- [x] TDD: extractor — `## Open questions` heading present → `has_open_questions=true`.
- [x] TDD: extractor — duplicate `[[Foo]]` in same note → 2 separate `ExtractedLink` rows with distinct `position`s.
- [x] TDD: extractor — 50k-char input completes < 50ms in tests (linear-time guard).
- [x] TDD: integration (`tests/links_integration.rs` new) — vault create + 2 notes; `reindex_note` populates `links` rows; `to_note_id` resolves on second pass after target note is created.
- [x] TDD: integration — schema v3 migration on a fresh vault is idempotent on a v3 vault.
- [x] TDD: integration (`tests/migration_v3.rs` new) — pre-seed v2 vault with duplicate titles via raw SQL → migrate → titles deduped (`Foo`, `Foo (2)`); `notes_dedup_log` populated with `migrated_at`; idempotent re-run.
- [x] TDD: integration — pre-seed v2 vault with 1,001 duplicate titles → migrate aborts with `TooManyDedupCollisions { count: 1001 }`; `schema_version` stays at 2; no rows mutated.
- [x] Verify: `cargo test --workspace && cargo clippy --workspace --all-targets -- -D warnings`.

### Phase 2: Title-rename pass + CLI `links` and `add-link`

- **Goal**: renaming a note rewrites all `[[OldTitle...]]` variants across linkers transactionally; `memex links` and `memex add-link` work end-to-end.
- [x] `crates/memex-core/src/notes.rs` — extend `update_note` signature with `RenameOptions { rename_links: bool }` (default true). On title change: validate new title (non-empty, ≤200 chars, no `~`/`|`/`]`/newline) → `TitleInvalid`; pre-check `UNIQUE` collision → `TitleConflict`; if `rename_links`, query backlinks via `links` table, rewrite each linker's `content_md` (body + frontmatter strings) replacing `[[OldTitle]]`, `[[OldTitle~kind]]`, `[[OldTitle|alias]]`, `[[OldTitle~kind|alias]]` → `[[NewTitle...]]` (preserving kind + alias). Reindex each touched note. **All in one transaction.**
- [x] `crates/memex-core/src/links.rs` — `add_link(vault, from_id, to_id, kind, label?, source) -> Link`; `remove_link(link_id)`. (Body markdown insertion happens in CLI/MCP layer; core only manages the table. Body insertion calls `update_note` with the modified `content_md`.)
- [x] `crates/memex-mcp/src/main.rs` — add `Commands::Links { vault, note_id, dir, kind? }` and `Commands::AddLink { vault, from, to, kind, label }` variants; `cmd_links` prints tree grouped by kind (built-ins first, user-defined alphabetically); `cmd_add_link` constructs new `content_md` per kind→destination rule (frontmatter for any non-`references` kind, built-in or user-defined; `## Auto-added links` section for `references`), calls `update_note`, returns JSON `{ link_id, from, to, kind, source, was_existing, note_version }`.
- [x] `crates/memex-mcp/src/main.rs` — add `--no-rename-links` flag to `Commands::Update`, thread to `update_note`.
- [x] `crates/memex-mcp/src/main.rs` — add `--include-links` flag to `Commands::Get` → output JSON gains `links` + `backlinks` arrays grouped by kind.
- [x] TDD: integration — `update_note` with new title rewrites every linker's `[[Old~kind]]` → `[[New~kind]]` (kind + alias preserved); collision → `TitleConflict`, no rows changed.
- [x] TDD: integration — `update_note` with `RenameOptions { rename_links: false }` only changes `notes.title`; linkers' `[[OldTitle]]` → ghost on next reindex.
- [x] TDD: integration — title-rename pass also rewrites frontmatter wikilinks (`extends: [[Old]]` → `extends: [[New]]`).
- [x] TDD: CLI subprocess — `memex add-link --kind contradicts` inserts into source frontmatter under `contradicts:` key.
- [x] TDD: CLI subprocess — `memex add-link --kind inspired-by` (user-defined) inserts into frontmatter under `inspired-by:` key.
- [x] TDD: CLI subprocess — `memex add-link` (no kind, default `references`) inserts into `## Auto-added links` section.
- [x] TDD: CLI subprocess — `memex add-link` is idempotent: second call returns existing link id with `was_existing: true`, no duplicate row.
- [x] TDD: CLI subprocess — `memex add-link --kind Made_Up` (invalid format) → structured `InvalidLinkKind` error, exit non-zero, nothing mutated.
- [x] TDD: CLI subprocess — `memex links --note-id <id>` prints expected tree from a hand-built fixture.
- [x] Verify: `cargo test --workspace && cargo clippy --workspace --all-targets -- -D warnings`.

### Phase 3: MCP additions — `get_note(include_backlinks)`, `neighbors`, `add_link`

- **Status (2026-05-04)**: complete. memex-core::graph::neighbors BFS, all three MCP tools wired, 13 new tool-smoke tests (16 total in tool_smoke.rs). 85 tests across the workspace; cargo clippy clean.
- **Goal**: agents read the link graph and add to it via MCP. Smoke tests pass against Claude Desktop.
- [x] `crates/memex-core/src/graph.rs` (new) — `neighbors(conn, note_id, depth, kind?)` BFS, depth-clamped 1..3, **excludes self-edges**. Returns `Vec<NeighborHit { note_id, title, distance, edges: Vec<EdgeMeta> }>`.
- [x] `crates/memex-core/src/lib.rs` — re-export `graph`.
- [x] `crates/memex-mcp/src/tools.rs` — wire up `GetNoteParams.include_backlinks` (already declared at `tools.rs:75`): when `true`, populate envelope with `links: Map<kind_string, Vec<LinkEntry>>` + `backlinks: Map<kind_string, Vec<LinkEntry>>` (built-in kinds first, user-defined alphabetically).
- [x] `crates/memex-mcp/src/tools.rs` — new tool `neighbors(NeighborsParams { note_id, depth?, kind? }) -> NeighborsEnvelope { vault_id, root_note_id, depth, results }`. Server-side depth clamp; kind validated via `LinkKind::new`; invalid kind → structured error.
- [x] `crates/memex-mcp/src/tools.rs` — new tool `add_link(AddLinkParams { from_id, to_id, kind?, label? }) -> AddLinkEnvelope { vault_id, link_id, from_id, to_id, kind, source, was_existing, note_version }`. Shares destination logic with CLI `cmd_add_link`. Kind normalized at server boundary.
- [x] TDD: smoke (`tests/tool_smoke.rs` extend) — `get_note(id, include_backlinks: true)` returns kind-keyed map shape against seeded vault with mixed built-in + user-defined kinds.
- [x] TDD: smoke — `neighbors(id, depth=2)` against fixture returns expected BFS edges; self-links excluded; `depth=99` clamped; invalid `note_id` → structured error; invalid `kind` → structured error.
- [x] TDD: smoke — `add_link(from, to, "contradicts")` writes to source frontmatter; `add_link(from, to, "inspired-by")` writes to frontmatter under user-defined key; `add_link(from, to)` (default) writes to `## Auto-added links`; second call returns `was_existing: true`; non-existent ids → `NotFound`.
- [x] Verify: `cargo test --workspace && cargo clippy --workspace --all-targets -- -D warnings`.

### Phase 4: Flutter editor — autocomplete + chip + bare-click navigation + backlinks panel

- **Goal**: typing `[[` opens caret-anchored popover; existing target inserts wikilink; non-existing creates note + inserts; bare click navigates wikilinks (auto-create-and-navigate for ghost links); chip cycles built-in kinds + opens user-defined picker; pinned backlinks panel below editor scroll region.
- [ ] `app/lib/src/db.dart` — add `linksOutFor(noteId)`, `linksInFor(noteId, {kind?})`, `allTitles({limit?, query?})`, `distinctLinkKinds()` reading from new `links` table.
- [ ] `app/lib/src/memex_cli.dart` — add `addLink(from, to, kind?, label?)`, `getNote(noteId)` (parses `memex get` JSON), `noRenameLinks` flag on `updateNote`.
- [ ] `app/lib/src/state/vault_state.dart` — add `linksOutProvider(noteId)` + `linksInProvider(noteId)` as `Provider.family`; `noteTitlesProvider` + `linkKindsProvider` reading via `VaultDb`. All re-read on `vaultRevisionProvider` bump.
- [ ] `app/lib/src/widgets/wikilink_autocomplete.dart` (new) — `WikilinkAutocompleteController` (Riverpod `Notifier<AutocompleteState>`): owns `query`, `AsyncValue<List<MatchHit>>` matches, `selectedIndex`, `isOpen`, `triggerOffset` (the byte offset of the `[[` that triggered). **Trigger rule: only opens on a keystroke event that produces a `[[` immediately before the caret.** Cursor-only movement does NOT trigger. Methods: `onKeystroke`, `onTextChanged`, `onSelectionChanged`, `selectExisting`, `selectCreate`, `dismiss`.
- [ ] `app/lib/src/widgets/wikilink_autocomplete.dart` — `WikilinkAutocompletePopover` widget: `OverlayEntry` anchored via `LayerLink` to a transparent target painted at the caret position (via `RenderEditable.getLocalRectForCaret`). List items + "+ Create" tail item. Keyboard handling via `Focus`/`Shortcuts`/`Actions` for ↑/↓/Enter/Esc.
- [ ] `app/lib/src/widgets/note_editor.dart` — wire the autocomplete controller into the body field via a key event listener (not just `addListener` on the controller); on accept-existing, splice `<Title>]]` after the existing `[[`; on accept-create, call `cli.addNote(title=query)` then splice. Bump `vaultRevisionProvider` after create.
- [ ] `app/lib/src/widgets/wikilink_text_controller.dart` (new) — custom `WikilinkTextEditingController` overriding `buildTextSpan` to apply styled `TextSpan` to `[[Title]]`/`[[Title~kind]]`/`[[Title|alias]]` ranges. Existing target = colored, no underline. Ghost = dashed underline + muted color + tooltip "Click to create". Compiled-once regex (`static final`); line-local rescan cache keyed on `text.hashCode`; debounced 120ms.
- [ ] `app/lib/src/widgets/wikilink_tap_overlay.dart` (new) — `Stack`ed transparent layer over the body field; `GestureDetector` listens to `onTapDown`, computes `renderEditable.getPositionForPoint(localTap)`, checks if it falls in a known wikilink range, and **bare-click navigates** (or auto-creates ghost target + navigates). Clicks outside ranges fall through to the editor (caret placement). Fallback path documented in spec req 20.
- [ ] `app/lib/src/widgets/kind_chip.dart` (new) — transient `OverlayEntry` shown after wikilink insertion at the position right after `]]`. Three quick buttons (built-in `extends`/`contradicts`/`example-of`) + "More…" button opening a fuzzy-search picker over `linkKindsProvider` + "Create new kind…" affordance for fresh user-defined kinds. Selection rewrites doc text from `[[Title]]` → `[[Title~kind]]` (or strips for `references`). **Dismiss only on cursor leave / Esc / 10s / focus loss** — NOT on every keystroke.
- [ ] `app/lib/src/widgets/backlinks_panel.dart` (new) — fixed-height pane mounted **below the editor scroll region** (not at the bottom of body content); always visible; collapse toggle (`Key('backlinks-panel-collapse')`). Reads `linksInProvider(currentNoteId)`. Built-in kinds first with friendly labels; user-defined kinds alphabetically below. Click navigates via `selectedNoteIdProvider`. Empty state: "No backlinks yet."
- [ ] `app/lib/src/widgets/note_editor.dart` — swap body controller to `WikilinkTextEditingController`; mount `WikilinkAutocompletePopover`, `WikilinkTapOverlay`, `KindChipOverlay`, and pin `BacklinksPanel` in the layout below the scroll region.
- [ ] Stable selectors: `Key('wikilink-popover')`, `Key('wikilink-popover-item-{title}')`, `Key('wikilink-popover-create')`, `Key('wikilink-{noteId}')`, `Key('wikilink-ghost-{title}')`, `Key('kind-chip')`, `Key('kind-chip-button-{kind}')`, `Key('kind-chip-more')`, `Key('backlinks-panel')`, `Key('backlinks-panel-collapse')`, `Key('backlink-item-{noteId}')`.
- [ ] TDD: widget — typing `[[F` opens popover with `Key('wikilink-popover')`; cursor-only movement into an existing `[[Foo]]` does NOT reopen popover.
- [ ] TDD: widget — typing a non-matching string shows `Key('wikilink-popover-create')` as last item; tapping it calls fake `MemexCli.addNote` and closes popover.
- [ ] TDD: widget — `↑/↓` change selection (assert highlighted item key); `Enter` inserts `[[Title]]`; `Esc` dismisses without inserting.
- [ ] TDD: widget — `WikilinkTextEditingController.buildTextSpan` applies different styles to `[[Title]]` (existing target) vs ghost.
- [ ] TDD: widget — bare click on an existing wikilink updates `selectedNoteIdProvider`; click outside ranges places caret normally.
- [ ] TDD: widget — bare click on a ghost wikilink calls fake `MemexCli.addNote` then updates `selectedNoteIdProvider`.
- [ ] TDD: widget — kind chip button selection rewrites `_bodyCtrl.text` correctly; chip stays visible across keystrokes; auto-dismisses 10s after insertion.
- [ ] TDD: widget — kind chip "More…" picker shows existing user-defined kinds plus "Create new kind…"; selecting a fresh kind rewrites doc.
- [ ] TDD: widget — backlinks panel renders incoming links grouped by kind (built-ins first); collapse toggle hides; click navigates; persists across body scroll.
- [ ] Robot journey (`app/test/wikilinks_journey_test.dart` new) — open temp vault → create note "Source" → focus editor → type `[[Targ` → assert popover opens → assert "+ Create" item visible → tap it → assert "Targ" appears in sidebar → click `Key('wikilink-Targ')` → assert `selectedNoteIdProvider == Targ.id` → assert backlinks panel shows "Source" under "References". Use `FakeMemexCli` (records calls, returns canned ULIDs) + real temp `VaultDb`. Wrap test app in `MaterialApp` for Overlay.
- [ ] Verify: `cargo test --workspace && cargo clippy --workspace --all-targets -- -D warnings && (cd app && flutter analyze && flutter test)`.

### Phase 5: Polish + docs + acceptance

- **Goal**: documentation matches reality; manual acceptance test passes through Claude Desktop.
- [ ] `README.md` — update "What works today" with wikilinks; mention two-tier kind vocabulary.
- [ ] `docs/wikilinks.md` (new) — user-facing primer: `[[Title]]` / `[[Title~kind]]` / `[[Title|alias]]` / `[[Title~kind|alias]]`; built-in 4 + user-defined kinds; section headings + frontmatter rules; ghost links; backlinks; `## Open questions`; documented limitations (case-sensitive titles, no code-block exclusion in v1, dedup-rename orphan-link behavior); migration triage flow if >1k duplicate titles.
- [ ] `docs/claude-desktop-setup.md` — list new MCP tools (`neighbors`, `add_link`) and updated `get_note(include_backlinks)`.
- [ ] `docs/acceptance-test.md` — extend with the spec's 7-step manual journey, plus a user-defined-kind step (e.g. ask Claude to create a `[[Foo~inspired-by]]` link via `add_link`).
- [ ] Manual acceptance run — record findings in `docs/wikilinks-debrief.md`.
- [ ] Verify: `cargo test --workspace && cargo clippy --workspace --all-targets -- -D warnings && (cd app && flutter analyze && flutter test)`. Manual: 7-step acceptance test passes against a real Claude Desktop session.

## Risks / Out of scope

**Risks (top 3):**
- **In-`TextField` wikilink rendering** is the load-bearing risk: `buildTextSpan` styling is fine, but tap interception via a `Stack`ed transparent overlay + `getPositionForPoint` is fiddly. If the first widget test reveals it as too fragile, fall back to "styled text only + a separate Links sub-panel listed below the editor." Lock-in decision point: Phase 4, first tap-routing widget test.
- **Schema v3 dedup-rename orphan-link** is documented but real: existing `[[Foo]]` references resolve to whichever sibling kept the bare title; the renamed sibling becomes unreachable from old links. Mitigation: dedup-log banner with per-note "review references" affordance. No automatic redirect in v1.
- **Title-rename pass scaling** is O(linkers × note size); fine for hundreds of linkers, painful for thousands. Documented as known limit. If it bites, switch to a regex pass per linker rather than full reread.

**Out of scope (deferred):**
- Transclusions (`![[Title]]` / block references with `^`).
- Slash-command shortcut for typed links.
- Hybrid-search graph signal (PageRank-lite).
- Auto-detection of kind from prose verbs.
- `[[?Title]]` shorthand (replaced by `## Open questions` heading).
- Code-block exclusion in extractor (documented limitation).
- Case-folded title matching (titles are case-sensitive in v1).
- User-defined section-heading kinds (e.g. `## Inspired by` auto-mapping to `inspired-by`) — body wikilinks need explicit `~kind` for non-built-in kinds in v1.
- Automatic link-redirect after dedup-rename (manual triage in v1).
