<goal>
Build a vertical-slice prototype of the AI-native memex — an open-source, local-first knowledge base whose primary "API" is a Model Context Protocol (MCP) server. The prototype must validate the core long-term architecture end-to-end:

- Flutter UI shell on macOS
- Rust core library shared between the app and a standalone MCP server binary
- SQLite as the on-device source of truth, with markdown content stored inside the database
- Hybrid search (FTS5 + vector via `sqlite-vec`) backed by local embeddings (`fastembed-rs`)
- Content-addressed attachment storage on the filesystem
- A standalone MCP server that Claude Desktop (or any MCP client) can connect to without the GUI running

**Why it matters:** The memex's long-term promises (offline-first, user-owned data, mobile + desktop, agent-native) are load-bearing on this architecture. A vertical slice is the cheapest way to learn whether the seams between Flutter, Rust, SQLite, sqlite-vec, fastembed-rs, flutter_rust_bridge, and the MCP protocol actually compose into a usable product before committing to ~6 months of full implementation.

**Who benefits:** The user (project owner) — they get a working prototype to type real notes into and exercise via Claude Desktop, surfacing architectural friction that is invisible on paper.

**Outcome:** Within ~1 week of build time, the user can:
1. Launch the macOS app, create or open a vault, type ~20 notes in a WYSIWYG markdown editor.
2. Configure Claude Desktop to point at the same vault via the standalone `memex-mcp` binary.
3. Ask Claude questions about the notes; Claude searches, retrieves, and (with permission) creates new notes.
4. Switch between multiple vaults in the app without restarting.
</goal>

<background>
**Working directory:** `~/code/open_src/open_memex/`

**Tech stack (decided in planning):**
- **Flutter** for UI (macOS only in the prototype; mobile + Windows/Linux deferred).
- **Rust** for the core library and MCP server, exposed to Flutter via **flutter_rust_bridge v2**.
- **SQLite** with **WAL mode**, **FTS5**, and the **sqlite-vec** extension. Single `memex.db` file per vault.
- **fastembed-rs** for local embeddings. Default model: `BAAI/bge-small-en-v1.5` (MIT license, 384-dim, ~33M params, runs on CPU).
- **MCP** (Model Context Protocol) over **stdio** transport for Claude Desktop integration.
- **appflowy_editor** (or equivalent) for live WYSIWYG markdown editing in Flutter.
- **ULID** for all stable identifiers (notes, chunks, attachments).

**Repository layout (Cargo workspace + Flutter app, monorepo):**
```
open_src/open_memex/
├── Cargo.toml                # workspace root
├── crates/
│   ├── memex-core/           # library crate: storage, indexing, search, embeddings, ingestion
│   └── memex-mcp/            # bin crate: standalone MCP server (depends on memex-core)
├── app/                      # Flutter macOS app
│   ├── lib/
│   ├── macos/
│   └── pubspec.yaml
├── rust_bridge/              # generated flutter_rust_bridge glue (checked in)
├── ai_specs/
│   └── prototype-vertical-slice-spec.md
├── docs/
│   └── claude-desktop-setup.md
└── README.md
```

**Out of scope (explicitly deferred):** sync / CRDTs (single-device only), mobile platforms, Windows/Linux desktop, web/audio/video/image ingestion, structured tables, plugin system, encryption at rest, embedding model migration tooling, multi-user collaboration, authentication.

**Files / docs to consult during implementation:**
- `flutter_rust_bridge` v2 docs (project setup + codegen workflow): https://cjycode.com/flutter_rust_bridge/
- `fastembed-rs` README for model selection and embedding API.
- `sqlite-vec` extension docs for vector schema and query syntax.
- `rmcp` (or `mcp_rust_sdk` — pick one mature crate) for the MCP server implementation; pin choice in spec implementation phase.
- `appflowy_editor` (or `super_editor`) docs for Flutter WYSIWYG editor integration.

**Naming conventions:**
- Rust: standard `snake_case` for functions/modules, `PascalCase` for types.
- Dart/Flutter: `camelCase` for vars/functions, `PascalCase` for classes, `snake_case` for files.
- Vault paths are absolute. Vault `id` is a ULID stored in `manifest.json` at the vault root.
</background>

<user_flows>
**Primary flow — first run:**
1. User launches `Memex.app`. No recent vaults exist.
2. App shows a vault picker screen with two actions: "Create new vault…" and "Open existing vault…".
3. User picks "Create new vault…", chooses a folder via macOS file picker, names it.
4. App creates `<folder>/manifest.json`, `<folder>/memex.db` (with schema applied), and empty `<folder>/objects/` directory.
5. App enters main window: empty note list on the left, empty-state message on the right.
6. User clicks "+ New Note", a new note opens in the editor with a default title.
7. User types markdown; on every quiet ~500ms the note is persisted and re-indexed.

**Primary flow — daily editing:**
1. User launches `Memex.app`. The most recently used vault auto-opens.
2. User selects a note from the sidebar; editor loads its content.
3. User edits; debounced save fires; background re-index updates FTS + embeddings.
4. UI surfaces a small "indexing…" indicator that clears within a few seconds.

**Primary flow — vault switching:**
1. User opens the vault menu (e.g. macOS menu bar → "Vault" → "Open Recent" / "Open Vault…").
2. User picks a different vault.
3. App closes the current SQLite handle, opens the new one, refreshes the sidebar and editor.
4. Recent vaults list updates; previously opened vault remains in the list.

**Primary flow — agent integration via Claude Desktop:**
1. User installs the `memex-mcp` binary (placed at a known path during build, e.g. `target/release/memex-mcp` or installed via `cargo install --path crates/memex-mcp`).
2. User edits `~/Library/Application Support/Claude/claude_desktop_config.json` to register the MCP server with arguments `--vault /absolute/path/to/vault`.
3. User restarts Claude Desktop; the memex tools (`search`, `get_note`, `create_note`) appear in Claude's tool list.
4. User asks Claude a question that requires their notes ("what did I write last week about X?").
5. Claude calls `search`, receives ranked chunks with provenance, optionally calls `get_note` for full context, returns an answer.
6. User asks Claude to create a new note; Claude calls `create_note`; the new note appears in the Flutter app on next refresh (and in the live note list if visible).

**Alternative flows:**
- *Skipped onboarding:* User dismisses the vault picker; app shows a "no vault open" state with a button to open/create one.
- *Vault opened by both Flutter app and MCP server simultaneously:* both processes use SQLite WAL mode; reads never block, writes are short and serialized by SQLite. Agent-initiated writes follow the same persistence path as Flutter-initiated writes.
- *Claude creates a note while user is editing a different note:* user's open editor is not affected; sidebar list reflects the new note on its next refresh tick (every ~2s while focused).

**Error / recovery flows:**
- *Vault folder missing or moved:* app shows clear error, removes from recents, returns to vault picker.
- *DB schema version mismatch (older DB, newer app):* if a forward migration exists, run it; otherwise show error with version info, do not auto-downgrade.
- *Embedding model not yet downloaded:* on first vault creation, app downloads model with progress UI. If user cancels or download fails, vault still opens; FTS works; semantic search disabled until model is present. UI shows clear status.
- *MCP write fails optimistic concurrency check:* server returns structured error including current `version`; agent can refetch and retry.
- *App crashes mid-save:* SQLite WAL guarantees the last committed write is durable. Indexing jobs are idempotent; on restart the in-progress indexing job is re-enqueued from a `pending_index` table.
- *Embedding model output dimension mismatch (wrong model loaded):* core refuses to write into the vector table and surfaces a fatal error rather than corrupt the index.
</user_flows>

<requirements>

**Functional — Rust core (`memex-core`):**

1. Provide a `Vault::create(path)` that initializes `manifest.json`, applies the SQL schema (with `sqlite-vec` virtual tables loaded), creates `objects/`, and returns a `Vault` handle.
2. Provide a `Vault::open(path)` that validates `manifest.json`, runs forward migrations as needed, opens the SQLite connection in WAL mode, and returns a `Vault` handle.
3. Provide note CRUD: `create_note`, `get_note`, `update_note`, `delete_note`, `list_notes(filter)`. All operations atomic via transactions. All reads return notes by ULID `id`.
4. Implement a chunker that splits a note's markdown into chunks of approximately 256–512 tokens, preferring boundaries at headings and paragraphs. Store chunks with `(note_id, ord, content, token_count, embed_model_version)`.
5. Implement an embedding pipeline using `fastembed-rs` with `bge-small-en-v1.5`. Embeddings stored in a `sqlite-vec` virtual table keyed by `chunk_id`.
6. Maintain an FTS5 virtual table (`chunk_fts`) over chunk content for lexical search.
7. Implement `search(query, k, filters)` that runs FTS5 + vector search in parallel, fuses results via Reciprocal Rank Fusion (k=60), applies optional filters (tag, date range, note_id whitelist), and returns ranked chunks with `{chunk_id, note_id, snippet, score, source: {note_title, ord}}`.
8. Implement an indexing queue (in-process) that debounces re-indexing per `note_id` (~500ms) and runs work on a background thread. Surface an "indexing" status flag readable by the UI.
9. Implement optimistic concurrency on `update_note`: every note has a `version` integer that increments on each write. `update_note` accepts an `expected_version`; mismatch returns a structured `VersionConflict` error with the current version.
10. Provide a stable, documented JSON-friendly API surface usable from both `flutter_rust_bridge` and the MCP server (no Dart- or MCP-specific types in `memex-core`).

**Functional — MCP server (`memex-mcp`):**

11. Standalone Rust binary linking `memex-core`. Accepts `--vault <path>` (required) and `--log-level` (optional, default `info`).
12. Speaks MCP over stdio. Negotiates protocol on startup; advertises three tools and (optional, time permitting) notes-as-resources.
13. Tool: `search(query: string, k?: int = 10, mode?: "hybrid"|"vector"|"fts" = "hybrid", tags?: string[])` → `{results: [{chunk_id, note_id, note_title, snippet, score}], truncated: bool}`. Default `max_tokens` budget ≈ 2000 tokens of snippets.
14. Tool: `get_note(note_id: string, include_backlinks?: bool = false, max_tokens?: int)` → `{note_id, title, content_md, frontmatter, version, created_at, updated_at, backlinks?: [...]}`. Truncates body if `max_tokens` exceeded and returns `truncated: true`.
15. Tool: `create_note(content_md: string, title?: string, tags?: string[])` → `{note_id, version}`. Created note has frontmatter `{source: "agent", agent_id: "<from MCP client info>", created_at}` and is auto-tagged `inbox` and `agent-authored`.
16. Every tool result includes a `source` block with the vault `id` and `note_id`/`chunk_id` so agents can reference results stably across calls.
17. The MCP server logs every tool call (tool name, args summary, result status) to a structured log file at `<vault>/.memex/mcp.log` with a max size and rotation.

**Functional — Flutter app (`app/`):**

18. macOS desktop app. Uses `flutter_rust_bridge` v2 to call into `memex-core` (linked as a static lib).
19. **Vault picker screen** at app launch when no vault is currently open. Shows recent vaults (persisted in app preferences), "Create new vault…" button, "Open vault…" button. Recent vaults that fail to open are surfaced with an error and offered for removal.
20. **Main window** with three regions: vault menu/title bar, note list sidebar (left), editor pane (right).
21. Note list: shows title + first-line snippet + updated timestamp, sorted by `updated_at` desc. Refreshes when notes change (poll every ~2s while focused; in-process change notifications later).
22. **Live WYSIWYG markdown editor** using `appflowy_editor` (or `super_editor` if integration is simpler — final choice during implementation). Supports headings, bold/italic, lists, links, code blocks, inline code. Backed by markdown text on save.
23. Debounced save: ~500ms after the last edit, the note is persisted via the bridge. Indicator in the title bar shows "saving…" / "indexing…" / clean states.
24. Vault switcher accessible from the macOS menu bar: "Vault" → "Open Recent…" (submenu of recents) and "Open Vault…" (folder picker) and "Create New Vault…".
25. New-note button creates a note with a default title ("Untitled") and opens it for editing.
26. App handles concurrent external writes (from MCP server) by polling for changes and refreshing the sidebar; if the open note's `version` advanced externally, prompt user before overwriting (basic conflict UI: keep mine / load theirs).

**Error Handling:**

27. All Rust-core errors are typed (`thiserror`) and serializable to a stable `{code, message, details?}` shape across the bridge and MCP boundary.
28. Bridge boundary never panics; panics in the Rust core are caught and converted to errors (`std::panic::catch_unwind` in the bridge entry points).
29. SQLite errors (busy, locked, IO) are retried with backoff up to a small bound (e.g. 3 retries / 200ms total) before surfacing.
30. Missing or corrupted vault: app surfaces error, removes from recents (with user confirmation), returns to vault picker. Never auto-deletes data.
31. `sqlite-vec` extension load failure: app exits with a clear startup error pointing at the build instructions. (This is a build/packaging issue, not a runtime user error.)
32. MCP `create_note` writes are wrapped in a single transaction; partial state never leaks if chunking/embedding fails afterward (indexing is enqueued post-commit).
33. Embedding model download failure: app does not block vault opening; surfaces a banner that semantic search is disabled and offers retry.
34. Tool args validation in the MCP server: invalid args return a structured error in the MCP response, never crash the server process.

**Edge Cases:**

35. Empty vault search returns `{results: [], truncated: false}` not an error.
36. Note with empty content: chunker produces zero chunks, search never returns it, but `get_note` returns it normally.
37. Very long note (>50k chars): chunker still produces a finite chunk count; embedding runs in batches; UI remains responsive (work happens off the UI thread).
38. Two MCP `create_note` calls in flight concurrently: each gets a unique ULID; SQLite serializes the inserts; both succeed.
39. App and MCP server both writing the same note's `update_note`: optimistic concurrency rejects the loser; loser surfaces error and refetches.
40. Vault folder placed inside iCloud Drive or other syncing folder: behavior is "best effort" — document the limitation, do not crash. (CRDT sync arrives in a later phase; iCloud is not officially supported.)
41. Switching vaults while a save is in flight: in-flight save completes against the old vault before the new vault's connection is opened. UI is locked briefly with a spinner.
42. Embedding model dimension mismatch (e.g. wrong model file present): startup check refuses to use the model; falls back to FTS-only with a banner.

**Validation:**

43. ULIDs validated at API entry points; malformed IDs return `InvalidId` errors with the offending value (truncated for safety in logs).
44. Vault path inputs validated to be absolute, exist, and be writeable before any file ops.
45. MCP tool args validated against a documented JSON schema; out-of-range `k`, empty `query`, etc. return structured errors.
46. SQL schema version is checked on every vault open; mismatch triggers migration or refusal-with-message, never silent data corruption.
</requirements>

<boundaries>
**Edge cases:**
- *Vault path on a network drive that disconnects mid-edit:* SQLite will surface IO errors; app shows error and disables editor until the user re-selects a vault.
- *User opens the same vault in two app instances:* SQLite WAL allows concurrent readers; only one writer at a time. Document this as unsupported but do not corrupt data — second instance shows a "vault busy" message.
- *Markdown with embedded HTML or unusual unicode:* stored as-is; chunker is unicode-safe; FTS5 tokenizer handles common cases. Exotic edge cases not tuned in prototype.
- *Note titles colliding:* allowed; uniqueness is by ULID, not title.

**Error scenarios:**
- *Embedding inference fails on a single chunk:* that chunk is skipped, others succeed; failure logged. Note remains searchable via FTS.
- *MCP transport disconnects mid-call:* server cleans up, exits with non-zero code; Claude Desktop restarts it on next call.
- *Disk full during write:* surface error, no partial commit (single transaction).

**Limits:**
- *Per-vault scale target for prototype:* up to ~2,000 notes, ~50,000 chunks. Beyond that, query latency and indexing throughput are not optimized in this phase.
- *Per-note size limit:* soft cap at 200,000 characters; warn user above this; do not block.
- *Concurrent indexing jobs:* serialized per vault; one indexer thread.
- *MCP response size:* default ~2,000 token snippet budget per `search`; ~8,000 token body cap on `get_note` (truncatable on request).
</boundaries>

<implementation>

**Files / modules to create:**

*Rust workspace:*
- `Cargo.toml` (workspace root, members: `crates/memex-core`, `crates/memex-mcp`).
- `crates/memex-core/Cargo.toml` — deps: `rusqlite` (with `bundled` + `vec` features as available), `sqlite-vec`, `fastembed`, `serde` / `serde_json`, `thiserror`, `ulid`, `tokio` (for the indexer queue), `tracing`.
- `crates/memex-core/src/lib.rs` — public API surface (Vault, Note, SearchResult, errors).
- `crates/memex-core/src/vault.rs` — open/create/manifest.
- `crates/memex-core/src/schema.rs` — SQL schema + migrations.
- `crates/memex-core/src/notes.rs` — CRUD with optimistic concurrency.
- `crates/memex-core/src/chunker.rs` — heading/paragraph chunker with token target.
- `crates/memex-core/src/embedder.rs` — `fastembed-rs` wrapper.
- `crates/memex-core/src/search.rs` — FTS + vector + RRF fusion.
- `crates/memex-core/src/indexer.rs` — debounced background queue.
- `crates/memex-core/tests/` — integration tests using a temp vault.
- `crates/memex-mcp/Cargo.toml` — deps: `memex-core`, chosen MCP crate (e.g. `rmcp`), `tokio`, `clap`, `tracing`.
- `crates/memex-mcp/src/main.rs` — CLI parsing, MCP server bootstrapping.
- `crates/memex-mcp/src/tools.rs` — tool definitions (`search`, `get_note`, `create_note`).

*Flutter app:*
- `app/pubspec.yaml` — deps: `flutter_rust_bridge`, `path_provider`, `shared_preferences`, `appflowy_editor` (or `super_editor`), `file_picker`.
- `app/lib/main.dart` — app entry, theming.
- `app/lib/bridge/` — generated `flutter_rust_bridge` Dart bindings (output of codegen, checked in).
- `app/lib/state/` — vault state (current vault, recents) using a simple holder (e.g. `ChangeNotifier` or `Riverpod` providers — pick the simplest that keeps tests trivial).
- `app/lib/screens/vault_picker.dart`.
- `app/lib/screens/main_window.dart`.
- `app/lib/widgets/note_list.dart`, `note_editor.dart`, `vault_status_bar.dart`.
- `app/macos/Runner/` — bundle the Rust static lib into the macOS app via the standard `flutter_rust_bridge` macOS recipe.

*Docs:*
- `docs/claude-desktop-setup.md` — exact `claude_desktop_config.json` snippet, install steps, troubleshooting.
- `README.md` — repo overview, build instructions, prototype scope.

**Patterns / libraries to use:**
- **flutter_rust_bridge v2** with codegen output checked into `app/lib/bridge/` and `rust_bridge/`. Regeneration happens on demand (`flutter_rust_bridge_codegen generate`), not on every flutter build.
- **rusqlite** with `sqlite-vec` loaded as a runtime extension (or compiled in if a `bundled-vec` feature is available). Decide during implementation; fall back to runtime extension load with a clear error if missing.
- **WAL mode** enabled on every connection (`PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL;`).
- **ULIDs** via the `ulid` crate.
- **MCP**: pick one Rust MCP crate (likely `rmcp` from the Anthropic ecosystem if it's mature; otherwise the `mcp_rust_sdk` or hand-roll the small subset needed). Pin the choice in the first implementation phase and document it.
- **Tracing** for structured logs in both Rust binaries (writes to `<vault>/.memex/mcp.log` for the MCP server, stderr for the bridge).

**What to avoid and why:**
- Do **not** add async ORMs (Diesel, SeaORM) — overkill for the prototype; raw `rusqlite` with hand-written SQL is faster to iterate on and easier to reason about.
- Do **not** use Postgres or any networked DB — see prior planning; SQLite is the only correct on-device store.
- Do **not** introduce CRDT libraries in this phase. The schema must leave room for a `crdt_state BLOB` column on `notes`, but the prototype uses last-write-wins with optimistic concurrency.
- Do **not** add a remote embedding API fallback in the prototype — it would obscure whether the local pipeline actually works. The user explicitly chose `fastembed-rs`.
- Do **not** ship a markdown editor framework that requires Web-only or that can't round-trip to plain markdown losslessly. WYSIWYG must serialize back to markdown text the chunker can read.
- Do **not** check generated bridge output into the same module twice (Rust + Dart paths must be the single canonical generated locations).
- Do **not** pre-build a plugin/extension system. YAGNI for the prototype.
- Do **not** silently skip or degrade vector search if the embedding model fails to load — show a clear banner; FTS-only must be a visible state, not a stealth fallback.
- Do **not** implement a custom MCP transport. Stdio only, exactly what Claude Desktop expects.
</implementation>

<stages>
**Phase 1 — Repo + bridge skeleton (verify: `cargo build --workspace` succeeds and Flutter app launches showing a Rust-greeting from the bridge).**
- Initialize Cargo workspace + Flutter app side by side.
- Wire up `flutter_rust_bridge` v2 codegen.
- Implement a single bridge function `hello_from_rust()` and render its output in the Flutter app.

**Phase 2 — Vault + schema (verify: integration test creates a vault, opens it, applies migrations; vault round-trips via the bridge from Flutter).**
- `Vault::create` / `Vault::open` with manifest + SQLite + WAL + sqlite-vec extension load.
- Schema: `notes`, `chunks`, `chunk_fts`, `chunk_vec`, `links`, `tags`, `attachments`, `pending_index`, `schema_version`.
- Bridge functions: `vault_create(path)`, `vault_open(path)`, `vault_close()`, `vault_info()`.

**Phase 3 — Notes CRUD + indexing pipeline (verify: integration test creates 20 notes, asserts FTS hits + embedding row counts; indexer flushes within target latency).**
- `create_note` / `update_note` / `get_note` / `list_notes` with optimistic concurrency.
- Chunker (heading + paragraph splitter, token-target window).
- `fastembed-rs` integration; first call triggers model download to a stable cache path.
- Indexer: debounced per-note background job; idempotent re-runs; `pending_index` durability.

**Phase 4 — Hybrid search (verify: integration test with seeded notes runs canned queries, asserts top-1 hit on each).**
- FTS5 search.
- Vector search via `sqlite-vec`.
- RRF fusion.
- Filters: `tags`, `note_id` whitelist (date filters optional).

**Phase 5 — Flutter app (verify: launching the app, creating a vault, writing a note, switching vaults, returning works without restarting).**
- Vault picker, recent vaults persistence.
- Main window, note list, WYSIWYG editor.
- Debounced save + status indicator.
- Vault switcher.
- Robot-driven journey test: open vault → create note → type → switch vault → switch back → note persists.

**Phase 6 — MCP server (verify: integration test that drives the binary over stdio and exercises all three tools; documented Claude Desktop config produces working tools in Claude).**
- `memex-mcp` binary with `--vault` arg.
- Stdio MCP transport.
- `search`, `get_note`, `create_note` tools with documented schemas.
- Logging to `<vault>/.memex/mcp.log`.
- `docs/claude-desktop-setup.md` written with copy-paste config.

**Phase 7 — End-to-end acceptance (verify: documented manual test journey passes against a seeded ~20-note vault).**
- Seeded fixture vault with diverse notes (technical, personal, journaled).
- Manual test script with ~10 questions Claude must answer correctly via tools.
- Capture friction notes for the post-prototype design review.

**Verification at the end of every phase:**
- All `cargo test --workspace` tests pass.
- `flutter test` passes for any widget tests added in that phase.
- The phase's specific manual or integration verification step succeeds.
- A short note in `docs/phase-N-notes.md` records what was learned and any deviations from the spec.
</stages>

<validation>

**Test layering:**

*Rust core (`memex-core`):*
- **Unit tests** for: chunker boundary correctness, RRF fusion math, ULID validation, optimistic concurrency rejection, schema migration application.
- **Integration tests** in `crates/memex-core/tests/` using a temp vault on `tempfile::TempDir`:
  - Create vault → assert manifest + DB exist + schema version matches.
  - Create 20 fixture notes, run a list of canned queries, assert expected top-k results (golden file).
  - Run two concurrent `update_note` calls, assert one succeeds and one returns `VersionConflict`.
  - Boot, write, close, re-open: data persists, indexes remain consistent.
  - Embedder dimension-mismatch fixture: core refuses to write into vector table.

*MCP server (`memex-mcp`):*
- **Integration test** that spawns the binary as a subprocess, drives it over stdio with the MCP protocol, exercises `search` / `get_note` / `create_note`, asserts schemas of responses.
- **Negative tests:** invalid args, nonexistent `note_id`, malformed JSON — all return structured errors and the server stays alive.

*Flutter app:*
- **Widget tests** for: vault picker (no recents → buttons; with recents → list rendered, click handlers fire), note list (renders titles, sorts by updated), save indicator state machine, vault switching flow.
- **Robot-driven journey test** (one critical journey, deterministic):
  - Open temp vault → click "+ New Note" → type "hello world" → wait for save indicator clean → switch vault → switch back → assert note "hello world" present.
  - Use stable selectors (`Key("note-list-item-{id}")`, `Key("editor-content")`, `Key("vault-switcher")`).
  - Inject the `memex-core` bridge with a fake/in-memory implementation for fast deterministic tests; have a separate slower test that exercises the real Rust core via a temp vault.

**TDD expectations (where applicable):**

For Rust core modules with non-trivial logic (chunker, RRF fusion, optimistic concurrency, indexer debouncing):
- Drive each module with a **behavior-first test slice**, RED → GREEN → REFACTOR per slice.
- Slice order: happy path → boundary cases → error/edge cases.
- Inject seams for determinism: pass a `Clock` trait to the indexer (so debounce is testable), pass a `Random` source to ULID generation (so ordering is deterministic in tests), pass an `Embedder` trait with a fake implementation for tests that don't need real inference.
- The Flutter app uses constructor-injected bridge dependencies so widget tests can swap in a fake `MemexCore` and remain deterministic and fast.
- Flutter UI rendering tests don't need to be strictly TDD; they're easier to write after the widget shape settles. Pure logic in Dart (state holders, formatters) should be TDD'd.

**Mocking policy:**
- Prefer **fakes** (in-memory implementations of small interfaces) over mock frameworks.
- Mock only true external boundaries: the embedding model in unit tests, the MCP transport in negative tests.
- Do **not** mock SQLite — use a real temp SQLite file in integration tests. The behavior of FTS5, sqlite-vec, and WAL is what we are validating.

**Baseline coverage outcomes required:**
- All Rust core modules have unit tests for their public functions; CI fails if `cargo test --workspace` fails.
- All MCP tools have at least one happy-path and one error-path integration test.
- Vault open/create + note CRUD + hybrid search have integration coverage end-to-end.
- One Flutter robot-driven journey test exists and runs in CI.
- Critical flows (vault create, vault switch, note save) have widget tests.

**Acceptance test (manual, documented):**

A `docs/acceptance-test.md` that walks through:
1. Build the workspace and the Flutter app.
2. Launch the app, create a vault at a known path.
3. Type 20 fixture notes (provided in `docs/fixture-notes.md` for copy-paste).
4. Configure Claude Desktop with the documented snippet pointing at the same vault.
5. Restart Claude Desktop; confirm tools are listed.
6. Run ~10 prepared questions through Claude, expecting answers grounded in the vault. Examples:
   - "What did I write about SQLite vs Postgres?" → expects retrieval of the relevant note.
   - "Find anything related to local-first architecture." → expects multiple chunks fused, ranked sensibly.
   - "Create a note titled 'Prototype debrief' summarizing my recent thoughts on storage." → expects `create_note` to fire; new note visible in app within ~2s.
7. Switch vaults in the app; confirm Claude (still pointed at the original vault) is unaffected.
8. Capture friction notes in `docs/prototype-debrief.md`.

The acceptance test is the primary validation that the architecture composes. Pass criteria are listed inline per question.
</validation>

<done_when>
1. `cargo build --workspace --release` succeeds on macOS.
2. `cargo test --workspace` passes.
3. `flutter build macos --release` produces a runnable `Memex.app`.
4. `flutter test` passes including the one robot-driven journey test.
5. Launching `Memex.app`, creating a vault, writing notes, switching vaults, and returning works smoothly with no crashes during a 15-minute exploratory session.
6. `memex-mcp --vault <path>` starts, advertises three tools over stdio, and survives malformed input without crashing.
7. With the documented `claude_desktop_config.json` snippet in place, Claude Desktop lists the memex tools and successfully answers all questions in `docs/acceptance-test.md` with grounded results.
8. Claude can create a note via `create_note`; the new note appears in the Flutter app's sidebar within ~2 seconds of being created and is correctly tagged `inbox` + `agent-authored`.
9. `docs/claude-desktop-setup.md`, `docs/acceptance-test.md`, `docs/fixture-notes.md`, and `docs/prototype-debrief.md` exist and are filled in.
10. `README.md` documents: prototype scope, build instructions, how to run the acceptance test, what's deferred.
11. Repo layout matches the structure in `<background>`. No stale generated files; no committed binaries.
</done_when>
