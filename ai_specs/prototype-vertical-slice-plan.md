# Open Memex — Prototype Plan

## Overview

Vertical-slice prototype: Flutter macOS app + Rust core (FRB v2) + SQLite (FTS5 + sqlite-vec) + standalone MCP binary. Phase 1 proves end-to-end Flutter→Rust→SQLite; later phases add search, MCP, UX polish, acceptance.

**Spec**: `ai_specs/prototype-vertical-slice-spec.md` (read for full requirements)

## Context

- **Repo**: greenfield monorepo at `~/code/open_src/open_memex/`. No git yet.
- **Layout**: Cargo workspace at root + Flutter app in `app/`. `crates/memex-core/` is FRB-free pure logic. `app/rust/` is a thin bridge crate (cdylib+staticlib) re-exporting a curated API; depends on `memex-core`.
- **State management**: Riverpod 3.x. `ProviderContainer` per test, `ref.invalidate` for vault swap.
- **Editor**: spec says WYSIWYG. Use `super_editor` 0.3.x. Fallback: `TextField` + `flutter_markdown` if super_editor blocks the timeline.
- **IDs**: spec says ULID; UUIDv7 is the better tech-of-record but keep ULID per spec.
- **Reference implementations**: none in this repo (greenfield). External: FRB Cargo Workspaces guide, sqlite-vec `simple-rust/demo.rs`, rmcp examples.
- **Pinned versions** (April 2026): `flutter_rust_bridge` 2.12, `rusqlite` 0.39 + `["bundled","load_extension","vtab","blob"]`, `sqlite-vec` crate 0.1, `fastembed` 5.13, `rmcp` 1.5 + `["server","transport-io","macros"]`, `ulid` 1.2.
- **Critical macOS detail**: link sqlite-vec **statically** via `cc` in `app/rust/build.rs` + `sqlite3_auto_extension(sqlite3_vec_init)` at startup. Runtime `load_extension` will fight the app sandbox.

## Plan

### Phase 1: Vertical slice — Flutter ↔ Rust ↔ SQLite end-to-end

- **Goal**: launch app, create vault, write a note via Flutter UI, persist through FRB→Rust→SQLite, restart, see note. Proves the bridge + storage path.
- **Status (2026-04-29)**: **Pivoted to MCP-server-first** — the user wanted to actually try the idea, and the AI-native thesis lives in the MCP server, not the GUI. Rust foundation + indexing + hybrid search + MCP server + Claude Desktop integration are all done. Flutter app deferred (note-creation surface is now Claude itself + the `memex add` CLI). Phase-2 / Phase-3 collapsed forward in this session.
- [x] `git init` + `.gitignore` (Rust `target/`, Flutter build, `.env`, `.DS_Store`)
- [x] `Cargo.toml` workspace root (members: `crates/memex-core`; `app/rust` to be added when FRB scaffolding lands)
- [x] `crates/memex-core/Cargo.toml` deps: `rusqlite` (bundled+load_extension+vtab+blob), `sqlite-vec`, `serde`/`serde_json`, `thiserror`, `ulid`, `tracing`
- [x] `crates/memex-core/src/lib.rs` — public types: `Vault`, `Note`, `MemexError`, `NoteId(Ulid)`
- [x] `crates/memex-core/src/vault.rs` — `Vault::create(path)`, `Vault::open(path)`. Static-register sqlite-vec via `sqlite3_auto_extension`. WAL + `synchronous=NORMAL` + `foreign_keys=ON` + busy_timeout
- [x] `crates/memex-core/src/schema.rs` — minimal v1 schema: `schema_version`, `notes(id TEXT PK, title, content_md, frontmatter JSON, version INT, created_at, updated_at, crdt_state BLOB NULL)`. Migration runner.
- [x] `crates/memex-core/src/notes.rs` — `create_note`, `get_note`, `list_notes(limit)`. Optimistic concurrency on `update_note(expected_version)` returning `VersionConflict`
- [x] TDD: vault create writes `manifest.json` + `memex.db` + `objects/` and applies schema (integration test on `tempfile::TempDir`)
- [x] TDD: round-trip — create note, close, re-open, list returns same content
- [x] TDD: `update_note` with stale `expected_version` returns `VersionConflict` carrying current version
- [x] **Bonus** TDD: sqlite-vec extension is loaded and usable (`vec0` virtual table create + KNN query). De-risks Phase 2 indexing.
- [ ] `app/rust/Cargo.toml` (cdylib+staticlib) depends on `memex-core` + `flutter_rust_bridge` 2.12
- [ ] `app/rust/build.rs` — compile `sqlite-vec` C source via `cc` (static link) — note: `sqlite-vec` crate already statically links via `cc` internally, so this may not be needed; verify when wiring `app/rust`
- [ ] `app/rust/src/api/mod.rs` — `#[frb]` API: `vault_create`, `vault_open`, `vault_close`, `note_create`, `note_get`, `note_list`. Wraps `memex-core` types in serializable DTOs
- [ ] `flutter_rust_bridge.yaml` at `app/` (rust_input → `app/rust/src/api`, dart_output → `app/lib/src/rust`)
- [ ] Run `flutter_rust_bridge_codegen create` then commit generated `app/lib/src/rust/**` and `app/rust/src/frb_generated.rs`
- [ ] `app/macos/Runner/` — Xcode build phase invoking `cargo build --release -p app_rust`. Podspec links `libapp_rust.a`. Swift dummy referencing one symbol to defeat dead-stripping
- [ ] `app/pubspec.yaml` deps: `flutter_rust_bridge`, `flutter_riverpod`, `path_provider`, `shared_preferences`, `file_picker`
- [ ] `app/lib/main.dart` — `ProviderScope` + initial route
- [ ] `app/lib/src/state/vault_state.dart` — `currentVaultProvider`, `notesProvider` (depends on currentVault), bridge wrapper providers
- [ ] `app/lib/src/screens/vault_picker.dart` — minimal: "Create new vault…" + "Open existing vault…" buttons via `file_picker`
- [ ] `app/lib/src/screens/main_window.dart` — note list (left) + plain `TextField` editor (right) — keep WYSIWYG editor for Phase 4
- [ ] `app/lib/src/widgets/note_list.dart`, `note_editor.dart` — debounced save 500ms via `Timer`
- [ ] TDD: bridge wrapper providers map errors `MemexError`→Dart sealed class; happy-path round-trip via fake bridge
- [ ] TDD: `currentVaultProvider` invalidate triggers `notesProvider` recompute (constructor-injected fake bridge)
- [ ] Robot journey: open temp vault → "+ New Note" → type "hello world" → wait for clean indicator → restart `ProviderContainer` → note "hello world" persists. Stable selectors: `Key('vault-picker-create')`, `Key('note-list-item-{id}')`, `Key('editor-content')`, `Key('save-indicator')`. Inject fake `Clock` for debounce determinism.
- [ ] Verify: `cargo test --workspace` && `cargo clippy --workspace -- -D warnings` && `flutter analyze` && `flutter test`. Manual: build+run app, create vault, write note, restart, note present.

**Validation that ran in this session (Rust slice only):**
- `cargo test --workspace` → 4/4 integration tests pass
- `cargo clippy --workspace --all-targets -- -D warnings` → clean
- Flutter analysis/tests not run because no Flutter app exists yet

**Phase 2 (indexing) and Phase 3 (MCP) work pulled forward in the 2026-04-29 session:**
- [x] memex-core schema v2: chunks, chunk_fts (FTS5), chunk_vec (sqlite-vec), tags, pending_index
- [x] Chunker module with paragraph/heading-based splitting and token-target packing (5 unit tests)
- [x] Embedder trait + FakeEmbedder (deterministic for tests) + FastEmbedder wrapping `fastembed-rs` BGE-small-en-v1.5
- [x] Inline indexer: rewrites chunks + FTS rows + vector rows in a single transaction on every note write
- [x] Hybrid search via Reciprocal Rank Fusion over FTS5 + vec0 results (4 integration tests)
- [x] memex-mcp binary `memex` with subcommands: `init`, `add`, `ls`, `serve`
- [x] MCP server (rmcp 1.5) over stdio with 3 tools: `search`, `get_note`, `create_note` (3 integration smoke tests)
- [x] Agent-authored notes auto-tagged `inbox` + `agent-authored` with frontmatter `source: "agent"`
- [x] Logs to `<vault>/.memex/mcp.log` with daily rotation
- [x] `docs/claude-desktop-setup.md` and `README.md` written

**Flutter app pulled forward in the 2026-05-01 session (architecture pivot: subprocess + direct SQLite read instead of FRB):**
- [x] `memex update --vault <p> --note-id <id> --expected-version <v>` and `memex get` subcommands added
- [x] Flutter macOS app scaffolded (`app/`); macOS sandbox disabled in entitlements so the app can spawn the `memex` binary and read the vault folder
- [x] State management with Riverpod 2.x: `settingsProvider`, `currentVaultProvider`, `vaultDbProvider`, `notesListProvider`, `selectedNoteProvider`, `editorControllerProvider`
- [x] `MemexCli` service: subprocess wrapper for `init`/`add`/`update`, with structured `MemexException` (incl. `versionConflict` kind)
- [x] `VaultDb`: read-only SQLite access to the vault via `sqlite3` package (writes go through the CLI to keep indexing in one place)
- [x] Vault picker screen with create / open / recents (and "memex binary not found" recovery path)
- [x] Main window: note list sidebar + plain-markdown editor with debounced save (~500ms) + save-status indicator (idle/dirty/saving/clean/error/conflict)
- [x] Optimistic concurrency surfaced as a "conflict — reload" indicator if an external write (e.g., from Claude) advances the version
- [x] Stable selectors on key widgets (`vault-picker-create`, `vault-picker-open`, `note-list-item-{id}`, `editor-content`, `editor-title`, `save-indicator`, `vault-switcher`, `new-note-button`)
- [x] Widget tests: 2 passing — vault picker empty state + recents rendering
- [x] `flutter analyze` clean, `flutter build macos --debug` builds successfully
- [x] README updated with quick-start for the Flutter app

**Decisions worth flagging:**
- **No `flutter_rust_bridge`.** The original plan had FRB v2 + a static-linked Rust library inside the macOS app bundle. Pivoted to: Flutter spawns the `memex` binary for writes, reads the SQLite file directly via `sqlite3` package. Rationale: avoids macOS Xcode build-phase wiring + sandbox-vs-extension-load issues, reuses the same binary already powering the MCP server, and keeps indexing logic single-sourced. Tradeoff: ~30-50ms subprocess spawn per write (acceptable for desktop note-creation latency).
- **macOS sandbox disabled.** Required for spawning `memex` and reading user-chosen vault paths. Acceptable for a local-first dev tool.
- **Plain `TextField` markdown editor**, not WYSIWYG. Spec called for `super_editor`; deferring per the plan's risk note about markdown round-trip lossiness. Easy to swap in later.

### Phase 2: Indexing pipeline + hybrid search

- **Goal**: notes are chunked, embedded with fastembed, FTS+vector indexes populated; `search()` returns ranked chunks via RRF.
- [ ] `crates/memex-core/Cargo.toml` add `fastembed` 5.13, `tokio` (rt+macros), `zerocopy`
- [ ] `crates/memex-core/src/schema.rs` — extend: `chunks(id TEXT PK, note_id, ord, content, token_count, embed_model_version)`, `chunk_fts USING fts5(content, content='chunks', content_rowid='rowid')`, `chunk_vec USING vec0(chunk_id TEXT PARTITION KEY, embedding float[384] distance_metric=cosine)`, `pending_index(note_id TEXT PK, enqueued_at)`, `tags(note_id, tag, PK(note_id,tag))`
- [ ] Schema migration v1→v2 applied on open
- [ ] `crates/memex-core/src/chunker.rs` — split markdown by headings then paragraphs, pack to 256–512-token windows with ~64-token overlap. Pure function. Trait `Tokenizer` injected for tests.
- [ ] `crates/memex-core/src/embedder.rs` — `Embedder` trait + `FastEmbedEmbedder` impl using `BGESmallENV15`. `InitOptions::with_cache_dir` to a stable path under app data dir. Dimension assertion at init (panic→error if not 384).
- [ ] `crates/memex-core/src/indexer.rs` — `Indexer` with debounced enqueue per `note_id`, single worker thread, idempotent re-runs, durable `pending_index` table. Inject `Clock` trait for test determinism.
- [ ] `crates/memex-core/src/search.rs` — `search(query, k, mode, filters)`. Run FTS5 BM25 + vec0 KNN in parallel, fuse with Reciprocal Rank Fusion (k=60), apply tag/note_id filters post-fusion, return `[{chunk_id, note_id, snippet, score, source:{title, ord}}]`.
- [ ] Bridge: `search` and indexing-status accessor
- [ ] TDD: chunker — happy: paragraph-split note → chunks within token window. Edge: empty content → 0 chunks. Edge: single >>512-token paragraph → still split. Edge: heading-only doc → handled.
- [ ] TDD: embedder — fake `Embedder` returns deterministic vectors; real fastembed integration test gated behind `--ignored` (downloads model)
- [ ] TDD: RRF fusion math — known fixture: two ranking lists, expected fused order
- [ ] TDD: indexer debounce — burst of N enqueues for same note → exactly 1 run after quiet period. Crash mid-run → restart re-enqueues from `pending_index`.
- [ ] TDD: search — seeded 20-note fixture, canned queries, golden top-1 assertions. FTS-only, vector-only, hybrid modes each return sensible results.
- [ ] TDD: dimension-mismatch — embedder returning wrong dim refuses to write to `chunk_vec`
- [ ] Verify: `cargo test --workspace` (incl. ignored embedder test gated on local env) && `cargo clippy` && `flutter analyze` && `flutter test`

### Phase 3: Standalone MCP server + Claude Desktop integration

- **Goal**: `memex-mcp --vault <path>` binary speaks MCP over stdio; Claude Desktop lists 3 tools and calls them successfully.
- [ ] `crates/memex-mcp/Cargo.toml` deps: `memex-core`, `rmcp` 1.5 (`["server","transport-io","macros"]`), `schemars`, `clap`, `tokio` (rt+macros), `tracing`, `tracing-subscriber`, `tracing-appender`
- [ ] `crates/memex-mcp/src/main.rs` — `clap` parses `--vault`, `--log-level`. Init tracing to `<vault>/.memex/mcp.log` with rotation. Open vault. Spawn `Memex.serve(stdio()).await?.waiting().await?`.
- [ ] `crates/memex-mcp/src/tools.rs` — `Memex` struct holds `Arc<Vault>`. `#[tool_router]` impl with three tools:
  - `search(query, k?, mode?, tags?)` → `{results, truncated}` with ~2k token snippet budget
  - `get_note(note_id, include_backlinks?, max_tokens?)` → `{note_id, title, content_md, frontmatter, version, created_at, updated_at, backlinks?}` with truncation flag
  - `create_note(content_md, title?, tags?)` → `{note_id, version}`. Adds frontmatter `{source:"agent", agent_id, created_at}`, auto-tags `inbox` + `agent-authored`. Single transaction; index enqueued post-commit.
- [ ] Param structs derive `serde::Deserialize + schemars::JsonSchema`
- [ ] Every tool response includes `source:{vault_id, note_id|chunk_id}`
- [ ] Tool args validation: empty query, invalid ULID, k out of range → structured `MemexError` returned in MCP response, server stays alive
- [ ] `docs/claude-desktop-setup.md` — copy-paste `claude_desktop_config.json` snippet, install instructions (`cargo install --path crates/memex-mcp`), troubleshooting
- [ ] TDD: integration test spawns `memex-mcp` subprocess, drives MCP protocol over stdio, exercises happy + error paths for all 3 tools (use `tokio::process::Command`)
- [ ] TDD: `create_note` from MCP appears in `notes` table with correct frontmatter + tags within transaction; indexing enqueued
- [ ] TDD: malformed JSON / invalid args → server responds with structured error and stays alive (next call succeeds)
- [ ] Verify: `cargo test --workspace` && `cargo clippy` && manual: register in Claude Desktop, restart, confirm 3 tools listed, exercise one of each.

### Phase 4: Multi-vault switcher + WYSIWYG editor + concurrent-write UX

- **Goal**: production-feel editor + vault swap; concurrent writes from MCP visible in app.
- [ ] `app/lib/src/state/recents.dart` — persist recent vaults in `shared_preferences`; surface failed-to-open recents with remove option
- [ ] `app/lib/src/screens/vault_picker.dart` — render recents list; click opens
- [ ] macOS menu bar: "Vault" → "Open Recent" submenu, "Open Vault…", "Create New Vault…"
- [ ] Vault switch flow: in-flight saves complete against old vault → close → open new → invalidate `currentVaultProvider` → UI shows brief spinner
- [ ] `app/pubspec.yaml` add `super_editor` 0.3.x + `super_editor_markdown`
- [ ] Replace `TextField` editor with `super_editor` configured to round-trip CommonMark via `super_editor_markdown`. Save path: doc → markdown text → `note_update`.
- [ ] Note-list polling (~2s while focused) for external changes; if open note's `version` advanced externally → conflict prompt (keep mine / load theirs / cancel)
- [ ] Save indicator state machine in title bar: idle / saving / indexing / error
- [ ] TDD: recents persistence — add, remove, surface-error-and-remove
- [ ] TDD: vault-switch invariants — in-flight save completes against old vault before swap (use fake `Clock` + injected bridge)
- [ ] TDD: conflict detection — external `update_note` while editor open → `version` mismatch → conflict UI shown
- [ ] TDD: super_editor markdown round-trip — input markdown → editor doc → output markdown → equal (within tolerated normalization)
- [ ] Robot journey extended: create vault A → write note → switch to new vault B → write different note → back to A → original note intact + clean
- [ ] Verify: `cargo test --workspace` && `flutter analyze` && `flutter test`. Manual: 15-min exploratory session, no crashes, all flows smooth.

### Phase 5: Acceptance test + prototype debrief

- **Goal**: documented manual journey through Claude Desktop against seeded vault confirms architecture composes; capture friction.
- [ ] `docs/fixture-notes.md` — 20 fixture notes spanning technical (sqlite vs postgres, local-first), personal (journal-style), reference (links/citations)
- [ ] `docs/acceptance-test.md` — step-by-step: build, launch, type fixtures, configure Claude Desktop, restart, ~10 prepared questions with pass criteria. Include the `create_note` round-trip test (Claude creates note → app shows within ~2s).
- [ ] `docs/prototype-debrief.md` — to be filled during run; sections: friction, surprises, validated assumptions, what to revisit before phase 2 of the broader project
- [ ] `README.md` — repo overview, prototype scope, build instructions, how to run acceptance test, deferred items
- [ ] Run the full acceptance test; record outcomes in debrief
- [ ] Verify: all 10 acceptance questions return grounded answers; `create_note` round-trip succeeds; `cargo test --workspace` && `flutter test` green; debrief file populated.

## Risks / Out of scope

**Risks (top 3):**
- **macOS sandbox + sqlite-vec**: must link statically + use `sqlite3_auto_extension`. If `bundled` rusqlite fights the static `sqlite-vec`, fallback is to use the upstream `cc`-compiled `sqlite-vec.c` directly and ensure single SQLite copy. Prove this on day 1 of Phase 1.
- **super_editor markdown lossiness**: if round-trip drops attributes, fall back to `TextField` + `flutter_markdown` preview for the prototype (still validates the architecture; defer WYSIWYG).
- **fastembed first-launch download** (~50MB): will surprise users on first vault creation. Surface clear progress UI; allow vault to open with FTS-only if download fails/skipped.

**Out of scope (deferred from prototype):** sync / CRDTs (single device only), mobile platforms, Windows / Linux desktop, web/audio/video/image ingestion, structured tables, plugin system, encryption at rest, embedding model migration tooling, multi-user collaboration, authentication, attachment ingestion (schema reserves space; no UI/MCP surface this phase).

**Spec deviations to note:**
- Spec specifies ULIDs; UUIDv7 (RFC 9562, native `uuid` crate v7 feature) is technically a stronger choice for SQLite. Keeping ULID per spec; reconsider before phase-2 of the broader project.
- Spec phase list has 7 phases; this plan consolidates to 5 by merging the FRB skeleton into the Phase-1 vertical slice and merging UX polish phases.
