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
  - `memex serve --root <dir> --listen <host:port>` — run the vault server: serve every vault in `<dir>` over HTTP to the app and agents on your trusted LAN or tailnet. `--listen` has no default. See [`docs/hosted-vault.md`](docs/hosted-vault.md) for a NAS, Linux or an always-on Mac
  - `memex serve --remote <url>` — bridge stdio MCP to a hosted vault (`<server-url>/vaults/<name>/mcp`, token from `MEMEX_ACCESS_TOKEN`), for Claude Desktop and Raycast
  - `memex vault check --vault <path>` — exit 0 when the folder is safe for a vault (not on a network drive)
  - `memex add --role daily|topic` — create a daily note or a topic note (`memex add --vault <path> --title 2026-09-05 --role daily`)
  - `memex append --vault <path> [--date YYYY-MM-DD] [TEXT]` — quick entry: append text to a daily note (today by default; text from the argument or stdin) and print the new block ids, the content version and the day's prior review state as JSON. The one CLI write meant for automation (Raycast, Alfred, Shortcuts, shell aliases).
  - `memex prompt review` / `memex prompt capture` — print the agent prompt texts
  - `memex rm --vault <path> --note-id <id> --expected-version <v>` — delete a note (people only; there is no MCP delete tool)
  - `memex excerpt rm` — remove one excerpt from a topic note; `memex footer add --vault <path> --note-id <id> --topic-note-id <id>` — add a topic to a note's Note footer
  - `memex tag add|rm --vault <path> --note-id <id> --tag <name>` — add or remove a tag in a note's footer; `memex tag ls --vault <path> [--note-id <id>]` — list every tag, or one note's tags and their origins; `memex ls --vault <path> --tag <name>` — list only the notes with that tag
  - `memex folder ls|new|update|rm|add|remove` — manage Smart Folders and their members; `memex settings get|set --key smart_folder_max_depth` — read or change a vault setting
  - `memex canvas …` — canvas operations (see [`docs/canvas.md`](docs/canvas.md))
- **Daily notes and agent review** (see [`docs/daily-review.md`](docs/daily-review.md), and [`docs/daily-acceptance.md`](docs/daily-acceptance.md) for the manual acceptance script):
  - The app opens on today's **daily note** with the cursor ready; nothing is written until you type. The sidebar switches between **Days** (a list by date, each row with a review dot: grey `Unreviewed`, green `Reviewed`, amber `Changed since review`) and **Topics** (the Smart Folder tree, with an Unsorted row).
  - Your agent (Claude Desktop, Claude Code, Raycast AI chat or any MCP client; the app never calls a model) **reviews** each day over MCP: it files blocks into **topic notes** as live **excerpts** (transclusions that show the day's current text), links related topics, groups them into **Smart Folders** and marks the day reviewed with a short change record, shown in each note's Activity tab. Daily notes show their **Note footer** as chips.
  - **Pinned** Smart Folders and memberships (everything you create or edit yourself) are respected by the agent, and `smart_folder_max_depth` (default 2) caps Smart Folder nesting for everyone; the app offers to raise it when you nest deeper.
  - A read-only **Graph view** of notes and wikilinks, opened from a Smart Folder, topic note or day.
  - **Capture**: type observations to a Claude Code session and each is appended verbatim to today's daily note and filed. Quick entry: `memex append` from any launcher; the next review files it.
- **Flutter macOS app** (`app/`) with vault picker, multi-vault recents, **tabbed workspace** (note + canvas tabs persist per-vault), note list, plain-markdown editor, debounced save, **wikilink autocomplete (`[[`) with create-on-the-fly**, **inline kind chip**, and a **real backlinks panel** grouped by kind
- **Canvas view**: user-curated boards where notes become draggable nodes and wikilinks render as labelled lines. Drag from the rail to place; drag from a node's edge handle to draw a typed link; click a line to edit kind/label; double-click a node to zoom into its editor. See [`docs/canvas.md`](docs/canvas.md).
- SQLite-backed vault (`memex.db`) with WAL, FTS5, and a `vec0` virtual table from `sqlite-vec`
- Markdown chunker + inline indexing on every note write
- Hybrid search: FTS5 (BM25) + optional vector (cosine) fused via Reciprocal Rank Fusion
- Local embeddings via `fastembed-rs` (`BGE-small-en-v1.5`, 384-dim) — opt-in with `--with-embeddings`
- **Wikilinks**: `[[Title]]`, `[[Title~kind]]`, `[[Title|alias]]`, `[[Title~kind|alias]]`. Two-tier kind vocabulary — four built-ins (`references`, `extends`, `contradicts`, `example-of`) get curated section headings + frontmatter shortcuts; user-defined kebab-case kinds are first-class for storage and `neighbors()` queries. See [`docs/wikilinks.md`](docs/wikilinks.md).
- 30 MCP tools:
  - search and links: `search`, `get_note` (with `include_backlinks`), `create_note` (with `role`), `neighbors`, `add_link`, `update_link`
  - canvases (see [`docs/canvas.md`](docs/canvas.md)): `list_canvases`, `get_canvas`, `create_canvas`, `add_to_canvas`, `remove_from_canvas`, `move_node`, `delete_canvas`
  - review: `list_unreviewed_days`, `get_daily_note_changes`, `mark_day_reviewed`
  - capture and excerpts: `append_to_daily_note`, `add_excerpt`, `remove_excerpt`
  - Smart Folders and settings: `list_smart_folders`, `create_smart_folder`, `update_smart_folder`, `delete_smart_folder`, `add_to_smart_folder`, `remove_from_smart_folder`, `get_vault_settings`
  - tags and footer topics: `list_tags`, `tag_note`, `untag_note`, `add_footer_topic`
- None of the tools renames, edits or deletes an existing note, and the only write into a daily note body is `append_to_daily_note`.
- 2 MCP prompts: `review_daily_notes` and `capture` (the same texts print with `memex prompt review` and `memex prompt capture`)

## Upgrading to schema V5

Daily notes, topic notes, review state and Smart Folders need schema V5. The first time the new `memex` binary (the CLI, `memex serve` or the app's `memex` calls) opens a vault, it migrates that vault to V5 in place. Older `memex` binaries refuse to open a V5 vault, so there is no going back except from a backup. Before you upgrade:

1. Quit the app and any MCP client, then back up the vault's `memex.db`, `memex.db-wal` and `memex.db-shm` (all three; the last two exist while a vault is open or was not closed cleanly).
2. Install the new `memex` binary and the new app together (`cargo install --path crates/memex-mcp --locked --force`, then rebuild the app). The app drives the binary at `~/.cargo/bin/memex`, and an old binary with a new app, or the reverse, will not work.
3. Restart your MCP clients afterwards: Claude Desktop keeps `memex serve` running from the old binary until you quit and reopen it. Do the same for Raycast and any other long-running MCP client.
4. Try the upgrade on a scratch vault first (`memex init` a new one, or run `docs/daily-acceptance.md`), not on your only copy.

## Upgrading to schema V6

Tags (where each tag came from, and the tags you removed) and feedback on reviews (Feedback and the Vault Guide) need schema V6. The first time the new `memex` binary opens a vault, it migrates that vault to V6 in place: it adds the new tables and columns and records the `#tags` already written in each note's body. It changes no note body. Older `memex` binaries refuse to open a V6 vault, so there is no going back except from a backup. Before you upgrade:

1. Quit the app, every MCP client (Claude Desktop, Raycast and any other) and any `memex serve` you started yourself, before the first V6 open. A `memex serve` left running from the old binary keeps writing to the vault without the V6 rules.
2. Back up the vault's `memex.db`, `memex.db-wal` and `memex.db-shm` (all three; the last two exist while a vault is open or was not closed cleanly).
3. Install the new `memex` binary and the new app together (`cargo install --path crates/memex-mcp --locked --force`, then rebuild the app), then reopen your MCP clients so they start the new `memex serve`.
4. Try the upgrade on a scratch vault first (a copy of your vault, or `memex init` a new one), not on your only copy, and compare a few note bodies afterwards.

A vault may hold one note with `role: guide` (the Vault Guide). If it already has two or more, the V6 migration stops and leaves the vault at V5 unchanged. Keep one: copy what you need out of the others, delete them with the previous `memex`, then open the vault again.

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

See [`docs/claude-desktop-setup.md`](docs/claude-desktop-setup.md) for the config snippet and troubleshooting, and [`docs/daily-review.md`](docs/daily-review.md) for the review and capture prompts, Claude Code and Raycast setup, `memex append` and recurring runs. Both the Flutter app and Claude can be pointed at the same vault simultaneously — SQLite WAL handles concurrent access. To reach a vault on another machine, run a vault server there and point Claude Desktop at it with `memex serve --remote <url>`; see [`docs/hosted-vault.md`](docs/hosted-vault.md).

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

- CRDTs (concurrent edits to one note are not merged automatically; a hosted vault is served by one vault server, see [`docs/hosted-vault.md`](docs/hosted-vault.md))
- Mobile platforms
- Windows / Linux desktop (Flutter app is macOS-only for now)
- Web / audio / video / image ingestion
- Structured tables (Notion-style)
- WYSIWYG markdown editor (current editor is plain `TextField` over markdown)
- In-editor wikilink rendering + click-to-navigate (today the right-panel Connections tab handles navigation; styled `TextSpan` + tap routing on `EditableText` is the v2 work)
- Plugin system
- Encryption at rest
- MCP tools that rename, edit or delete existing notes (people do those through the app or `memex update` and `memex rm`; by design agents only create notes, append to daily notes, file excerpts, and write footer text with `tag_note`, `untag_note` and `add_footer_topic`, including on daily notes, never the person's own text)
- Transclusion of whole notes (`![[Title]]`); only blocks of daily notes can be transcluded, as excerpts

## License

MIT
