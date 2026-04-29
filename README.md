# Open Memex

Open-source, local-first, AI-native knowledge base. The user's notes live on their device. AI agents access them through a standard MCP server.

**Status: prototype.** This is the MCP-server-first vertical slice — enough to actually use the system end-to-end via Claude Desktop, with the desktop GUI deferred.

## What works today

- `memex` CLI binary that doubles as an MCP server:
  - `memex init <path>` — create a vault
  - `memex add --vault <path> --title ... --tags ...` — append a note (body from stdin)
  - `memex ls --vault <path>` — list notes
  - `memex serve --vault <path>` — run as an MCP server over stdio (for Claude Desktop, etc.)
- SQLite-backed vault (`memex.db`) with WAL, FTS5, and a `vec0` virtual table from `sqlite-vec`
- Markdown chunker + inline indexing on every note write
- Hybrid search: FTS5 (BM25) + optional vector (cosine) fused via Reciprocal Rank Fusion
- Local embeddings via `fastembed-rs` (`BGE-small-en-v1.5`, 384-dim) — opt-in with `--with-embeddings`
- 3 MCP tools: `search`, `get_note`, `create_note`

## Architecture

```
┌──────────────────────────────────────┐
│   Claude Desktop (or any MCP client) │
└──────────────┬───────────────────────┘
               │ MCP / stdio
┌──────────────▼───────────────────────┐
│           memex-mcp binary           │
│  • search / get_note / create_note   │
└──────────────┬───────────────────────┘
               │ in-process
┌──────────────▼───────────────────────┐
│            memex-core                │
│  • Vault (SQLite + manifest)         │
│  • Notes CRUD + optimistic concurrency│
│  • Chunker + Indexer                 │
│  • Hybrid search (FTS + vec0 + RRF)  │
│  • Embedder (fastembed-rs, optional) │
└──────────────────────────────────────┘
```

A future Flutter desktop app will sit alongside the MCP server, sharing the same vault file.

## Quick start

```bash
# Build & install
cargo install --path crates/memex-mcp --locked

# Create a vault
memex init ~/Documents/MyMemex

# Add a note
echo "# Hello\n\nThis is my first note." | \
  memex add --vault ~/Documents/MyMemex --title "Hello"

# Wire to Claude Desktop
# See docs/claude-desktop-setup.md
```

Then ask Claude things about your notes. See [`docs/claude-desktop-setup.md`](docs/claude-desktop-setup.md) for the config snippet and troubleshooting.

## Repo layout

```
open_memex/
├── Cargo.toml                 # workspace root
├── crates/
│   ├── memex-core/            # storage, indexing, search, embeddings
│   └── memex-mcp/             # CLI + MCP server binary (`memex`)
├── ai_specs/                  # spec + plan
├── docs/                      # user-facing docs
└── README.md
```

## Tests

```bash
cargo test --workspace
cargo clippy --workspace --all-targets -- -D warnings
```

## What's deferred

- Sync / CRDTs (single device only)
- Mobile platforms
- Web/audio/video/image ingestion
- Structured tables (Notion-style)
- Plugin system
- Encryption at rest
- A Flutter UI (planned next)
- `update_note` / `delete_note` exposed as MCP tools

## License

MIT
