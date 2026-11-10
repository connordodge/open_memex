# Connecting Open Memex to Claude Desktop

This walks you through wiring up the `memex` MCP server so Claude Desktop can search, read, and create notes in your vault.

## 1. Install the binary

Install Open Memex from the [Releases page](https://github.com/connordodge/open_memex/releases) (see the README's Install section). The app ships the `memex` binary, the Bundled memex, at:

```
/Applications/Open Memex.app/Contents/MacOS/memex
```

Claude Desktop runs that path directly, so you do not need anything else on your `PATH` for it. To type `memex` commands in a terminal, run the `ln -s` step in the [README](../README.md) once. The shell commands in this guide assume it.

To build from source instead, from the repo root:

```bash
cargo install --path crates/memex-mcp --locked
```

This puts a binary called `memex` at `~/.cargo/bin/memex`. Confirm:

```bash
which memex
memex --help
```

## 2. Create a vault

Pick a folder to hold the vault. It doesn't need to exist yet — `memex init` will create it. Use an absolute path.

```bash
memex init ~/Documents/MyMemex
```

You'll see something like:

```
Initialized vault
  path:        /Users/you/Documents/MyMemex
  vault_id:    01KQAFAQ66A7P1HCMRPY304AXK
  schema_ver:  5
```

Take note of the absolute vault path — you'll plug it into Claude Desktop's config next.

## 3. Add a few seed notes (optional but recommended)

So you have something for Claude to actually search. Body comes from stdin. Examples:

```bash
echo "# Storage decisions

We chose SQLite over Postgres because the app is local-first. Postgres
requires a server process, which kills the offline-first promise." \
| memex add --vault ~/Documents/MyMemex --title "Storage decisions" --tags arch

echo "# Local-first principles

User data lives on the user's device. Running a vault server is an
optional extra, not a requirement. The app must work fully offline forever." \
| memex add --vault ~/Documents/MyMemex --title "Local-first principles" --tags arch,principles

memex ls --vault ~/Documents/MyMemex
```

You can also have Claude create notes once we've wired things up.

## 4. Configure Claude Desktop

This section points Claude Desktop at a local vault. For a hosted vault on a vault server (a NAS, a Linux box or an always-on Mac), use the `--remote` config in [Hosted vault](hosted-vault.md) instead.

Open your Claude Desktop config:

- macOS: `~/Library/Application Support/Claude/claude_desktop_config.json`

Add (or merge into) the `mcpServers` block:

```json
{
  "mcpServers": {
    "memex": {
      "command": "/Applications/Open Memex.app/Contents/MacOS/memex",
      "args": [
        "serve",
        "--vault", "/Users/YOUR_USERNAME/Documents/MyMemex"
      ]
    }
  }
}
```

> Use **absolute paths** for both the binary and the vault — Claude Desktop will not expand `~` or `$HOME`. If you built from source, use the path of the binary you built (`/Users/YOUR_USERNAME/.cargo/bin/memex`) as the `command` instead.

### With semantic (vector) search enabled

The default config above uses **FTS5 only** — fast keyword search, no model download. To enable hybrid (FTS + vector cosine) search, add the `--with-embeddings` flag:

```json
"args": [
  "serve",
  "--vault", "/Users/YOUR_USERNAME/Documents/MyMemex",
  "--with-embeddings"
]
```

The first time Claude calls `search` or `create_note` with this flag, the BGE-small-en-v1.5 model (~130MB) will download into `<vault>/.memex/models/`. Subsequent runs reuse the cached model.

## 5. Restart Claude Desktop

Fully quit and re-open it. Claude Desktop keeps `memex serve` running from whichever binary it started, so do this after every app upgrade and every `cargo install` from source too (see "Upgrading to schema V5" in the [README](../README.md) before you point a new binary at an existing vault). After restart, you should see the memex tools in Claude's tools panel. The server exposes 37 tools; the README lists them all. The core ones:

- `search` — hybrid keyword + semantic search across your notes.
- `get_note` — fetch the full content of a note. Pass `include_backlinks: true` to also receive `links` (outgoing) and `backlinks` (incoming) maps grouped by kind.
- `create_note` — create a new note (auto-tagged `inbox` + `agent-authored`). A tag name outside the tag grammar is rejected with `invalid_argument`.
- `neighbors` — BFS over the link graph from a starting note. Treats edges as undirected for traversal but preserves direction in `EdgeMeta`. Self-edges excluded. Server-side depth clamp to `[1, 3]`. Optional `kind` filter.
- `add_link` — add a wikilink from one note to another. `kind=references` (default) appends to a `## Auto-added links` section; any other kind (built-in or user-defined kebab-case) writes into YAML frontmatter under that key. Idempotent.

The rest cover canvases (`list_canvases`, `get_canvas`, `create_canvas`, `add_to_canvas`, `remove_from_canvas`, `move_node`, `delete_canvas`), daily-note review (`list_unreviewed_days`, `get_daily_note_changes`, `mark_day_reviewed`), capture and excerpts (`append_to_daily_note`, `add_excerpt`, `remove_excerpt`) and Smart Folders (`list_smart_folders`, `create_smart_folder`, `update_smart_folder`, `delete_smart_folder`, `add_to_smart_folder`, `remove_from_smart_folder`, `get_vault_settings`), tags and footer topics (`list_tags`, `tag_note`, `untag_note`, `add_footer_topic`), plus `update_link`.

The server also offers two prompts, `review_daily_notes` and `capture`. Attach one from the `+` menu in a chat. See [`docs/daily-review.md`](daily-review.md) for what they do.

## 6. Try it

Open a new chat and try things like:

- *"What did I write about SQLite?"* — Claude calls `search`, then `get_note` for the top hit and answers with citations.
- *"Find anything related to local-first software."* — multi-result retrieval.
- *"Create a note titled 'Prototype debrief' summarizing my recent thoughts on storage."* — Claude calls `create_note`; the new note appears in the Flutter app's sidebar within ~2s.
- *"Tell me what links to my memex-architecture note."* — Claude calls `get_note(include_backlinks=true)` and reads off the backlinks grouped by kind.
- *"What notes are connected to this idea, two hops out?"* — Claude calls `neighbors(note_id, depth=2)` and walks the graph.
- *"Add a `contradicts` link from this note to the one about server-as-source-of-truth."* — Claude calls `add_link`; the source note's frontmatter gains `contradicts: [[Server-as-source-of-truth]]`. The link shows up immediately in the Flutter app's right-panel Connections tab.
- *"From this note, link to a new idea I'm 'inspired-by'."* — Claude can use any kebab-case kind; `inspired-by` joins the user's vocabulary and the chip's "More…" picker surfaces it next time.

## 7. Troubleshooting

**Tools don't appear in Claude after restart.**

- Check `~/Library/Logs/Claude/mcp*.log` — Claude logs MCP server startup failures there.
- Run the same command Claude would in a terminal: `/path/to/memex serve --vault /absolute/path/to/vault`. It should start and wait for stdio input. Hit Ctrl-C; look for any error.
- Double-check both paths are absolute and the vault folder exists.

**Vault not found.**

The path in `args` must point at a vault folder that contains `manifest.json` and `memex.db`. Run `memex init <path>` first if needed.

**Search returns nothing.**

Make sure you've actually added notes — `memex ls --vault ...` should list them. Notes added before the MCP server's vault path was set will work fine; the binary opens the vault on every connection.

**Where do logs go?**

`memex serve` writes to `<vault>/.memex/mcp.log` (rolled daily). You can tail it while talking to Claude:

```bash
tail -f ~/Documents/MyMemex/.memex/mcp.log.*
```

## Notes / known limits (prototype)

- Single-vault per Claude Desktop config entry. To switch vaults, edit the config and restart.
- A live editing UI (Flutter macOS app) is shipped — see the main README. The Flutter app and Claude Desktop can be pointed at the same vault simultaneously; SQLite WAL handles concurrent access.
- This guide uses a local vault: a folder on this Mac's own disk. To use one vault from several devices, run a vault server and connect to the hosted vault; see [Hosted vault](hosted-vault.md).
- There are no MCP tools to edit, rename or delete an existing note, by design. Claude can create notes, link them, append to daily notes and file excerpts; editing and deleting are yours, through the app or the CLI (`memex update`, `memex rm`).
- `tag_note`, `untag_note` and `add_footer_topic` write footer text only, including on daily notes, and never your own text; `tag_note` accepts only tags you have already written in your notes (`list_tags`).
- Schema is versioned (currently V5); upgrades run forward migrations when a newer `memex` opens a vault, and older binaries refuse a newer vault. Don't manually edit `memex.db`.
