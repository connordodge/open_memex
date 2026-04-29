# Connecting Open Memex to Claude Desktop

This walks you through wiring up the `memex` MCP server so Claude Desktop can search, read, and create notes in your vault.

## 1. Install the binary

From the repo root:

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
  schema_ver:  2
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

User data lives on the user's device. Sync is an enhancement, not a
requirement. The app must work fully offline forever." \
| memex add --vault ~/Documents/MyMemex --title "Local-first principles" --tags arch,principles

memex ls --vault ~/Documents/MyMemex
```

You can also have Claude create notes once we've wired things up.

## 4. Configure Claude Desktop

Open your Claude Desktop config:

- macOS: `~/Library/Application Support/Claude/claude_desktop_config.json`

Add (or merge into) the `mcpServers` block:

```json
{
  "mcpServers": {
    "memex": {
      "command": "/Users/YOUR_USERNAME/.cargo/bin/memex",
      "args": [
        "serve",
        "--vault", "/Users/YOUR_USERNAME/Documents/MyMemex"
      ]
    }
  }
}
```

> Use **absolute paths** for both the binary and the vault — Claude Desktop will not expand `~` or `$HOME`.

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

Fully quit and re-open it. After restart, you should see the memex tools listed in Claude's tools panel:

- `search` — keyword/semantic search across your notes
- `get_note` — fetch the full content of a note by id
- `create_note` — create a new note (auto-tagged `inbox` + `agent-authored`)

## 6. Try it

Open a new chat and try things like:

- *"What did I write about SQLite?"* — Claude should call `search`, then `get_note` for the top hit, and answer with citations.
- *"Find anything related to local-first software."* — multi-result retrieval.
- *"Create a note titled 'Prototype debrief' summarizing my recent thoughts on storage."* — Claude calls `create_note`; verify it appears with `memex ls --vault ...`.

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
- No live editing UI yet — you create notes via `memex add`, via Claude, or by appending to existing notes via Claude's `create_note` tool.
- No sync. The vault is single-device.
- `update_note` is not yet exposed via MCP — Claude can create new notes but cannot edit existing ones in this build.
- Schema is versioned; future upgrades will run forward migrations. Don't manually edit `memex.db`.
