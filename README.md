# Open Memex

Open-source, local-first, AI-native knowledge base. The user's notes live on their device. AI agents access them through a standard MCP server.

**Status: prototype.** Two ways to use it: a Flutter macOS desktop app for typing/editing notes, and an MCP server for AI agents (e.g. Claude Desktop) to read, search, and write the same vault.

## What works today

- `memex` CLI binary that doubles as an MCP server:
  - `memex init <path>` — create a vault
  - `memex add --vault <path> --title ... --tags ...` — append a note (body from stdin)
  - `memex update --vault <path> --note-id <id> --expected-version <v> [--no-rename-links]` — update a note (body from stdin); title changes auto-rewrite `[[OldTitle]]` in linkers transactionally
  - `memex get --vault <path> --note-id <id> [--include-links]` — print a note as JSON, optionally with links + backlinks
  - `memex ls --vault <path>` — list notes
  - `memex links --vault <path> --note-id <id> [--dir in|out|both] [--kind <k>]` — print the link tree
  - `memex add-link --vault <path> --from <id> --to <id> [--kind <k>] [--label <s>]` — insert a wikilink, idempotent
  - `memex serve --vault <path>` — run as an MCP server over stdio (for Claude Desktop, etc.)
- **Flutter macOS app** (`app/`) with vault picker, multi-vault recents, **tabbed workspace** (note + canvas tabs persist per-vault), note list, plain-markdown editor, debounced save, **wikilink autocomplete (`[[`) with create-on-the-fly**, **inline kind chip**, and a **real backlinks panel** grouped by kind
- **Canvas view**: user-curated boards where notes become draggable nodes and wikilinks render as labelled lines. Drag from the rail to place; drag from a node's edge handle to draw a typed link; click a line to edit kind/label; double-click a node to zoom into its editor. See [`docs/canvas.md`](docs/canvas.md).
- SQLite-backed vault (`memex.db`) with WAL, FTS5, and a `vec0` virtual table from `sqlite-vec`
- Markdown chunker + inline indexing on every note write
- Hybrid search: FTS5 (BM25) + optional vector (cosine) fused via Reciprocal Rank Fusion
- Local embeddings via `fastembed-rs` (`BGE-small-en-v1.5`, 384-dim) — opt-in with `--with-embeddings`
- **Wikilinks**: `[[Title]]`, `[[Title~kind]]`, `[[Title|alias]]`, `[[Title~kind|alias]]`. Two-tier kind vocabulary — four built-ins (`references`, `extends`, `contradicts`, `example-of`) get curated section headings + frontmatter shortcuts; user-defined kebab-case kinds are first-class for storage and `neighbors()` queries. See [`docs/wikilinks.md`](docs/wikilinks.md).
- 13 MCP tools: `search`, `get_note` (with `include_backlinks`), `create_note`, `neighbors`, `add_link`, `update_link`, plus `list_canvases` / `get_canvas` / `create_canvas` / `add_to_canvas` / `remove_from_canvas` / `move_node` / `delete_canvas` (see [`docs/canvas.md`](docs/canvas.md))

## Architecture

```
┌──────────────────────────┐    ┌──────────────────────────┐
│   Flutter macOS app      │    │   Claude Desktop         │
│   (vault picker + edit)  │    │   (or any MCP client)    │
└──────────┬───────────────┘    └──────────┬───────────────┘
           │ subprocess +                  │ MCP over stdio
           │ direct SQLite read            │
           │                               │
   ┌───────▼───────────────┐       ┌───────▼───────────────┐
   │   memex add/update/   │       │   memex serve         │
   │   get/ls/init         │       │   (MCP server)        │
   └───────┬───────────────┘       └───────┬───────────────┘
           │                               │
           │   single `memex` binary       │
           └───────────────┬───────────────┘
                           │ in-process
                ┌──────────▼───────────────┐
                │       memex-core         │
                │  • Vault (SQLite)        │
                │  • Notes CRUD + opt.con. │
                │  • Chunker + Indexer     │
                │  • Hybrid search (RRF)   │
                │  • Embedder (optional)   │
                └──────────────────────────┘
                           │
                ┌──────────▼───────────────┐
                │   <vault>/memex.db       │  ← shared
                │   <vault>/objects/       │
                │   <vault>/manifest.json  │
                └──────────────────────────┘
```

The Flutter app and the MCP server both go through the same `memex` Rust binary for writes (so indexing logic lives in one place), and SQLite WAL mode lets them share the vault concurrently.

## Quick start

```bash
# Build & install the CLI / MCP server
cargo install --path crates/memex-mcp --locked

# Create a vault
memex init ~/Documents/MyMemex

# Add a note
printf '# Hello\n\nThis is my first note.\n' | \
  memex add --vault ~/Documents/MyMemex --title "Hello"
```

### Flutter desktop app

```bash
cd app
flutter run -d macos       # development
# or
flutter build macos        # release build at build/macos/Build/Products/Release/
```

On first launch, click "Open existing vault…" and pick the same folder, or "Create new vault…" to make a fresh one. The app finds the `memex` binary at `~/.cargo/bin/memex` automatically.

### Claude Desktop integration

See [`docs/claude-desktop-setup.md`](docs/claude-desktop-setup.md) for the config snippet and troubleshooting. Both the Flutter app and Claude can be pointed at the same vault simultaneously — SQLite WAL handles concurrent access.

## Repo layout

```
open_memex/
├── Cargo.toml                 # workspace root
├── crates/
│   ├── memex-core/            # storage, indexing, search, embeddings
│   └── memex-mcp/             # CLI + MCP server binary (`memex`)
├── app/                       # Flutter macOS desktop app
├── ai_specs/                  # spec + plan
├── docs/                      # user-facing docs
└── README.md
```

## Tests

```bash
cargo test --workspace
cargo clippy --workspace --all-targets -- -D warnings
cd app && flutter analyze && flutter test
```

## What's deferred

- Sync / CRDTs (single device only)
- Mobile platforms
- Windows / Linux desktop (Flutter app is macOS-only for now)
- Web / audio / video / image ingestion
- Structured tables (Notion-style)
- WYSIWYG markdown editor (current editor is plain `TextField` over markdown)
- In-editor wikilink rendering + click-to-navigate (today the right-panel Connections tab handles navigation; styled `TextSpan` + tap routing on `EditableText` is the v2 work)
- Plugin system
- Encryption at rest
- `update_note` / `delete_note` exposed as MCP tools (Flutter app uses them via CLI today)
- Transclusions (`![[Title]]`)

## License

MIT
