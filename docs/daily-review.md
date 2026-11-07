# Daily notes, topics and agent review

Open Memex opens on today's daily note. You type; your own agent (Claude, or any MCP client) later files what you wrote into topic notes. This page explains the model, the two prompts that drive the agent, how to connect Claude Desktop, Claude Code and Raycast AI chat, how to add to today from a shell or launcher with `memex append`, and how to schedule recurring reviews.

The app depends on none of the agent setup below. It never calls a model, never holds an API key, and the app never launches, schedules or supervises an agent. Everything on this page runs outside the app, against the same vault.

To run the whole thing end to end on a throwaway vault, follow [`docs/daily-acceptance.md`](daily-acceptance.md).

## 1. The model

- **Daily note**: the one note per calendar day that you type into. Its title is the ISO date (`2026-09-05`), its frontmatter has `role: daily`, and dates use your machine's local time zone.
- **Block**: one paragraph, list item or heading of a daily note. Each block has a short stable id that survives edits to its text. Ids live in the vault database, never in the note body.
- **Topic note**: a note about one subject (`role: topic`) that accumulates excerpts across days. The agent creates topic notes, and you can create them too.
- **Excerpt**: the block range of a daily note that a topic note shows. It is a **transclusion**, a `![[2026-09-05#^b7k2m9]]` link written into the topic note under a `## 2026-09-05` heading. The topic note displays the live text of those blocks, so nothing is duplicated and an edit to the daily note shows up everywhere. If the block is later deleted, the excerpt reads `removed from 2026-09-05`.
- **Note footer**: the managed block at the bottom of every daily note, below the `<!-- memex:topics -->` marker, holding a `[[Topic~about]]` link for each topic that holds an excerpt from that day. In the editor it appears as a row of chips. Everything above the marker is yours; the server maintains everything below it.
- **Smart Folder**: an agent-maintained group of topic notes. A topic note can sit in several Smart Folders and Smart Folders can nest, up to the vault's depth limit (setting `smart_folder_max_depth`, default 2, range 1 to 5; a top-level Smart Folder is depth 1).
- **Pinned**: a flag on a Smart Folder, or on one topic note's membership in a Smart Folder, that the agent must not remove, rename, re-parent or delete. Anything you create in the app is pinned, an edit you make to an agent-created Smart Folder pins it, and you can switch the flag off to hand the item back. An agent may still add topic notes to a pinned Smart Folder.
- **Reviewed**: every daily note is `Unreviewed` (never reviewed), `Reviewed` (the agent has filed its current content) or `Changed since review` (you edited it afterwards). Any edit to your text makes the day unreviewed again with no agent action. The state shows as a dot on the Days row and a chip in the note header. Footer updates never change it.
- **Review**: one agent run that takes each unreviewed day, files its new and changed blocks into topic notes as excerpts, links topic notes that refer to each other, places new topic notes in Smart Folders, and marks the day reviewed with a short record (one to three bullets per touched note) that shows in each note's Activity tab.
- **Capture**: you type an observation to the agent; it appends your words verbatim to today's daily note and files the new blocks the way a review would.

The sidebar browses the vault two ways: **Days** (a list by date) and **Topics** (the Smart Folder tree with an Unsorted row for topic notes in no Smart Folder). A **Graph view** opens from a Smart Folder, a topic note or a day and shows the notes and wikilinks around it, laid out automatically.

### What the agent can and cannot do

The rules below are enforced by the MCP server for every call, so a weakly prompted agent still cannot damage the vault.

- It never rewrites, reorders or deletes your text in a daily note. Its only write into a daily note body is `append_to_daily_note`, which adds blocks above the Note footer. Filing goes through `add_excerpt` and `remove_excerpt`, which also maintain the Note footer; the agent never writes transclusion or footer syntax itself.
- `tag_note`, `untag_note` and `add_footer_topic` write footer text only, including on daily notes, and never your own text: a tag an agent applies is a line in the Note footer, not a `#tag` in the body. `tag_note` applies only tags from `list_tags`, the tags you have already written in your notes, and never one you removed from that note.
- It cannot rename, delete or merge notes: there is no MCP tool for it. Deleting a note is yours alone (`Delete note` in the app, or `memex rm`).
- It respects pinned items and the depth limit, and `mark_day_reviewed` fails with `review_stale` if you edited the day after the agent fetched it.

The tools a review uses, in the order a review uses them: `list_unreviewed_days`, `get_daily_note_changes`, `search`, `get_note`, `create_note` (with `role: topic`), `add_excerpt`, `add_link`, `get_vault_settings`, `list_smart_folders`, `create_smart_folder`, `add_to_smart_folder`, `list_tags`, `tag_note`, `mark_day_reviewed`. The full list of 37 tools is in the [README](../README.md).

## 2. The two prompts

The server exposes two MCP prompts. The same text is printed by the CLI, so you can use them from a client that does not support MCP prompts.

**`review_daily_notes`** (`memex prompt review`). The agent lists the unreviewed days, takes the oldest first, fetches only the blocks that changed, searches for a matching topic note before creating one, adds excerpts, links topic notes that refer to each other (for example with kind `extends`), places new topic notes in Smart Folders within the depth limit, respects pinned items, tags the day and the topic notes it touched with tags you already use (`list_tags`, then `tag_note`; a `Tagged #name` bullet records each one), marks the day reviewed with the version it fetched and a change entry for every note it touched (including the daily note), and repeats until no day is left.

**`capture`** (`memex prompt capture`). For the rest of the session every message you send is an observation, not a question. The agent appends it verbatim to today's daily note with `append_to_daily_note`, files the returned blocks into topic notes, and replies with one short sentence saying where it went. It marks the day reviewed only when the day was already `Reviewed` before the append (`prior_state`). If the day held earlier text nobody had filed, or the version check fails, it runs a full review of the day first so that nothing is hidden by the mark.

To print them:

```bash
memex prompt review
memex prompt capture
```

Output is the raw prompt text, no JSON. In Claude Code the prompts are also slash commands: `/mcp__memex__review_daily_notes` and `/mcp__memex__capture`. In Claude Desktop, attach a prompt from the `+` menu under the `memex` server.

## 3. Connecting a client

All three clients launch the same server, `memex serve`, over stdio. Use absolute paths for the binary and the vault. Install the binary with `cargo install --path crates/memex-mcp --locked`.

### Claude Desktop

Follow [`docs/claude-desktop-setup.md`](claude-desktop-setup.md) (install, vault, config, restart). After you upgrade `memex`, fully quit and reopen Claude Desktop so it restarts `memex serve`. Then start a chat, attach the `review_daily_notes` prompt, and send it.

### Claude Code

Register the server once, then start a session in any directory:

```bash
claude mcp add --scope user memex -- /Users/YOU/.cargo/bin/memex serve --vault /Users/YOU/Documents/MyMemex
claude
```

Inside the session, run `/mcp__memex__review_daily_notes` for a review, or `/mcp__memex__capture` to turn the session into a capture session. Claude Code asks permission the first time it uses each tool; approve the `memex` tools for the session, or allow them up front (see section 5).

### Raycast AI chat

Add `memex` as an MCP server in Raycast's MCP server settings (the menu names change between Raycast versions) with the same stdio config Claude Desktop uses:

```json
{
  "mcpServers": {
    "memex": {
      "command": "/Users/YOU/.cargo/bin/memex",
      "args": ["serve", "--vault", "/Users/YOU/Documents/MyMemex"]
    }
  }
}
```

Raycast chat may not offer MCP prompts. Give the chat this one-sentence capture instruction in the chat's custom instructions, or paste the output of `memex prompt capture` there for the full version:

> Treat every message I send as an observation: append it verbatim to today's daily note with `append_to_daily_note`, file the returned blocks into topic notes with `add_excerpt`, and reply in one short sentence saying where it went.

### Tags from the shell

People tag notes from the CLI too: `memex tag add --vault <path> --note-id <id> --tag <name>` and `memex tag rm --vault <path> --note-id <id> --tag <name>` change a note's footer tags, and `memex tag ls --vault <path>` lists every tag (add `--note-id <id>` for one note's tags and their origins). `memex ls --vault <path> --tag <name>` lists only the notes with that tag. `memex footer add --vault <path> --note-id <id> --topic-note-id <id>` adds a topic to a note's Note footer.

## 4. Quick entry with `memex append`

`memex append` adds text to a daily note without any agent: no filing happens and no model is involved. Use it from Raycast scripts, Alfred, Shortcuts or a shell alias.

```bash
memex append --vault /Users/YOU/Documents/MyMemex "Call the dentist before Friday"
```

It prints one JSON object on stdout:

```json
{"vault_id":"01HV…","note_id":"01J9…","date":"2026-10-03","block_ids":["b7k2m9"],"content_version":4,"version":9,"prior_state":"Reviewed"}
```

(The ids are 26-character ULIDs in real output; `…` stands for the rest.) The fields:

- `date`: the daily note that received the text (today in local time, or the day you pass with `--date YYYY-MM-DD`). The daily note is created if the day has none.
- `block_ids`: the new blocks, marked in the editor as added via quick entry.
- `content_version` and `version`: the day's content version (it counts edits to your text) and the note's save version.
- `prior_state`: the day's review state just before the append. In the example the day was `Reviewed`, so it is now `Changed since review`, and the next review files the new block.

The text comes from the argument, or from stdin when you omit it, which suits multi-line input:

```bash
printf 'Idea: coyote time for ledge grabs\n\nAlso check the jump arc.\n' | memex append --vault /Users/YOU/Documents/MyMemex --date 2026-10-03
```

The text lands verbatim at the end of your section, above the Note footer, separated from earlier text by a blank line. If the app has that daily note open, the new blocks appear within a couple of seconds without moving your cursor.

## 5. Recurring reviews

Reviews do not need a person present. Both examples below run the review prompt and nothing else.

### Claude Desktop scheduled task

If your Claude Desktop offers scheduled tasks, create one that runs every evening with this prompt, using the `memex` MCP server:

> Review my Open Memex daily notes: run the `review_daily_notes` prompt from the memex server and follow it until no unreviewed day is left.

Claude Desktop must be running at the scheduled time.

### cron with `claude -p`

`claude -p` runs Claude Code once without a session and prints the result. Register the server first (section 3), then add a crontab entry (`crontab -e`) that passes the review prompt text from `memex prompt review` and pre-approves the `memex` tools, since nobody is there to click Allow:

```cron
0 21 * * * /Users/YOU/.local/bin/claude -p "$(/Users/YOU/.cargo/bin/memex prompt review)" --allowedTools "mcp__memex" >> /Users/YOU/memex-review.txt 2>&1
```

This runs at 21:00 every day. Use absolute paths because cron has a minimal `PATH` (find yours with `which claude`). Check the result in the output file, or in the app: reviewed days turn green and each touched note's Activity tab lists what changed.

## 6. Who is calling: the safety model

Caller identity is the transport. A call that arrives over MCP is the agent; a call made through the `memex` command line, including every write the app makes, is you. The pinned, marker and append-only rules guard MCP calls only, because the command line is your own channel and is not guarded against whoever runs it. (The Smart Folder depth limit is different: the server enforces it for every caller.)

So do not give an agent shell access to the `memex` write subcommands (`add`, `update`, `rm`, `add-link`, `excerpt rm`, `footer add`, `tag add`, `tag rm`, `folder`, `settings` and the rest). An agent with a shell could rewrite a daily note, delete a note or unpin a Smart Folder, and none of the protections above would apply. Connect agents through `memex serve` only. `memex append` is the one CLI write intended for automation: it can only add new text at the end of a daily note and never edits or removes anything you wrote.

If you automate `memex append` from a script, remember that anything it adds will be filed by the next review as if you had typed it.
