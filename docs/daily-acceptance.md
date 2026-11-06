# Acceptance test — daily notes, topics and agent review

Manual journey to confirm the daily note, topic and review slice works end to end through the Flutter app, the `memex` CLI and a real Claude Code session acting as the agent. It covers review, capture, Raycast-style quick entry with `memex append`, pinning and Smart Folder depth. Background: [`docs/daily-review.md`](daily-review.md).

Everything runs against a scratch vault that this script creates with `memex init`. Never point it at your real vault.

## Prereqs

- `memex` built from this branch and installed at `~/.cargo/bin/memex`, on your `PATH`:
  `cargo install --path crates/memex-mcp --locked --force`.
  This replaces the `memex` that the app and Claude Desktop use for your real vault, and the first time the new binary opens a vault it migrates it to schema V5 (older binaries then refuse that vault). If your real vault is not backed up yet, do that first (see the V5 upgrade note in the README) or run this script on a machine or account where that does not matter.
- Flutter macOS app built from this branch (`cd app && flutter run -d macos`).
- Claude Code installed and signed in (`claude --version`).
- One terminal for the whole script, so the variables below stay set.

Create the scratch vault and a config that connects Claude Code to it and to nothing else:

```bash
export SCRATCH="$(mktemp -d)"
export VAULT="$SCRATCH/vault"
memex init "$VAULT"
printf '{"mcpServers":{"memex":{"command":"%s","args":["serve","--vault","%s"]}}}\n' "$(command -v memex)" "$VAULT" > "$SCRATCH/mcp.json"
echo "$VAULT"
```

**Expected**: `memex init` prints `schema_ver:  5` and the path under your temporary directory. Every Claude Code command below passes `--mcp-config "$SCRATCH/mcp.json" --strict-mcp-config`, so the session cannot reach any other vault, even if you registered `memex` with Claude Code before.

## 1. Seed two days and launch on today's daily note

1. Write two past daily notes as the person (the CLI is your channel):
   ```bash
   printf 'Fixed the jump arc.\n\n- tried coyote time\n\nSleep was bad.\n' \
     | memex add --vault "$VAULT" --title 2026-09-05 --role daily
   printf 'Jump arc still feels floaty at high speed.\n\nSlept better, in bed by 22:00.\n' \
     | memex add --vault "$VAULT" --title 2026-09-06 --role daily
   ```
2. Launch the app and choose `Open existing vault…`, then pick the path printed by `echo "$VAULT"`.
3. **Expected**: the app opens on a `Today` tab showing an empty daily note with a date header (no editable title) and the cursor ready in the body. Nothing is written to the vault until you type.
4. In the sidebar, the `Days` mode is selected. **Expected**: the list shows a `Today` row, then 2026-09-06 and 2026-09-05 grouped by month, each with a grey dot (`Unreviewed`).
5. Open 2026-09-05. **Expected**: the header carries a grey `Unreviewed` chip, and the body is exactly the three blocks you wrote.

## 2. Run a review with Claude Code

1. In another terminal tab, from the scratch directory, start a session:
   ```bash
   cd "$SCRATCH" && claude --mcp-config "$SCRATCH/mcp.json" --strict-mcp-config
   ```
   (Set `SCRATCH` there too, or use the path `echo "$SCRATCH"` printed.)
2. Run `/mcp__memex__review_daily_notes` and approve the `memex` tools when asked.
3. **Expected**: the agent starts from the oldest day, 2026-09-05, then 2026-09-06. For each day it lists what changed, searches for a matching topic note before creating one, creates topic notes (for example about the jump or about sleep), files blocks with `add_excerpt`, links topic notes that refer to each other, places new topic notes in Smart Folders, and marks the day reviewed. It ends by telling you what it did, and it never asks you to edit anything. Today's empty note is not listed.
4. Check one day from the terminal. Use `memex ls --vault "$VAULT"` to find its note id, then:
   ```bash
   memex get --vault "$VAULT" --note-id <id of 2026-09-05>
   ```
   **Expected**: `review.state` is `Reviewed`; `latest_change` holds one to three one-sentence bullets; `content_md` still begins with your three blocks exactly as written, and below the `<!-- memex:topics -->` marker there is a `[[Some topic~about]]` link for each topic note that holds an excerpt from that day.

## 3. Check topics, excerpts, the Note footer and Graph view

1. Back in the app, look at the Days list. **Expected**: both seeded days now show a green dot. Open one and hover its chip: **expected** a `Reviewed` chip with a hover text such as `Reviewed by agent at 5 Sep 2026, 14:32`.
2. Click the chip. **Expected**: the right panel opens its `Activity` tab with the agent's bullets, newest first, with the day reviewed.
3. At the bottom of the daily note, look at the Note footer. **Expected**: one chip per topic note that holds an excerpt from that day. Click one: the topic note opens.
4. Switch the sidebar to `Topics`. **Expected**: the Smart Folder tree shows the agent's Smart Folders with the topic notes in them (no pinned glyph, because you created none), and an `Unsorted` row last.
5. In a topic note, find the excerpt cards. **Expected**: each card shows your block text with a date caption such as `2026-09-05`. Click the caption: the daily note opens. Go back, edit the wording of one filed block in the daily note, and return: **expected** the card already shows your new wording (an excerpt is live, never duplicated), and the daily note's chip is now amber `Changed since review`.
6. Open the note menu on a topic note and choose `Open graph`. **Expected**: a Graph view tab opens with the topic note as a circle, the daily notes it draws from as small squares labelled by date, and the Smart Folder as a soft background shape behind its topic notes. You can pan, zoom and drag a node; nothing is saved.
7. Click `×` on one excerpt card. **Expected**: the card goes, and if the topic holds nothing else from that day, the daily note's Note footer loses that chip.

## 4. Capture from a live Claude Code session

1. In the Claude Code session from section 2 (or a new one started the same way), run `/mcp__memex__capture`.
2. Type three observations, one per message, exactly as shown:
   - `Coyote time of 0.1s makes ledge jumps feel fair`
   - `Need to look into rope physics for the grappling hook`
   - `Slept badly again, screens late`
3. **Expected**: after each message the agent replies with one short sentence naming the day it was added to and the topic notes it filed the observation under (or saying it only went into today's daily note). It does not answer, discuss or rewrite the observation.
4. In the app, open today's daily note. **Expected**: your three observations appear as separate blocks, word for word, in the order typed, with a thin rule in the gutter beside them; hovering it shows `captured via agent` with the time. They slid in without you reloading.
5. Send a fourth observation, and while the agent works on it, type a sentence in today's note in the app. **Expected**: both your sentence and the agent's block are present afterwards; neither of you loses text.
6. Check the review state. **Expected**: the first observation of the day found today `Unreviewed` (a new day), so the agent ran a full review of the day before marking it; later ones found it `Reviewed` and marked it again right away. After the last capture, with no edits of yours pending, today's chip is green `Reviewed` and the Note footer lists the topic notes involved. If you typed in step 5, the chip is amber until the next review.

## 5. Raycast-style quick entry with memex append

1. From the terminal, append to today without any agent:
   ```bash
   memex append --vault "$VAULT" "Raycast: buy coffee beans"
   ```
   **Expected**: one JSON object with `date` set to today, one id in `block_ids`, `content_version`, `version`, and `prior_state` (`Reviewed` if section 4 ended clean).
2. Append to a past day, and from stdin:
   ```bash
   printf 'Idea: ledge grab buffer\n\nAlso retest the jump arc.\n' \
     | memex append --vault "$VAULT" --date 2026-09-05
   ```
   **Expected**: `date` is `2026-09-05`, and `block_ids` has two ids (two blocks).
3. In the app, open today's daily note. **Expected**: the new block appears within a couple of seconds, your cursor and scroll do not move, and the gutter caption reads `added via quick entry` with the time.
4. **Expected**: the chips for today and for 2026-09-05 are amber `Changed since review`. No topic note changed: nothing filed these blocks yet.
5. In the Claude Code session, run `/mcp__memex__review_daily_notes` again. **Expected**: the agent lists the two days, fetches only the new blocks (it does not re-file the old ones), files them, and marks both days reviewed. The chips turn green and the Activity tab of each touched note has a new entry.

## 6. Pinning: the agent respects what you pinned

1. Create a pinned Smart Folder yourself and put a topic note in it (use real ids from `memex folder ls --vault "$VAULT"`):
   ```bash
   memex folder new --vault "$VAULT" --name "Game feel"
   memex folder add --vault "$VAULT" --id <id of Game feel> --note-id <id of a topic note>
   ```
   **Expected**: both print `"pinned":true`. In the app's `Topics` mode the `Game feel` Smart Folder shows a pinned glyph.
2. In Claude Code, ask: `Using only the memex tools, rename the Smart Folder "Game feel" to "Feel", then remove the topic note from it, then delete it.`
3. **Expected**: each attempt fails with a `pinned_rule` error naming the pinned item, the agent says so and stops, and `memex folder ls --vault "$VAULT"` shows `Game feel` and its member unchanged.
4. Ask: `Add another topic note to "Game feel".` **Expected**: this succeeds, because the agent may add topic notes to a pinned Smart Folder.
5. Hand the Smart Folder back to the agent:
   ```bash
   memex folder update --vault "$VAULT" --id <id of Game feel> --pinned false
   ```
   Ask the agent again to rename it to `Feel`. **Expected**: the rename succeeds. (A pinned membership would still stop the agent from removing that topic note from the Smart Folder.)

## 7. Smart Folder depth

1. Read the limit:
   ```bash
   memex settings get --vault "$VAULT" --key smart_folder_max_depth
   ```
   **Expected**: `"value":2` (a top-level Smart Folder is depth 1).
2. Make a child and then try a grandchild yourself:
   ```bash
   memex folder new --vault "$VAULT" --name Systems
   memex folder new --vault "$VAULT" --name Input --parent-id <id of Systems>
   memex folder new --vault "$VAULT" --name Gamepad --parent-id <id of Input>
   ```
   **Expected**: the second command succeeds with `"depth":2`. The third exits non-zero and prints an error with `"code":"depth_exceeded"`, `"max_depth":2` and `"required_depth":3`.
3. In Claude Code, ask: `Create a Smart Folder "Gamepad" under "Input".` **Expected**: the `create_smart_folder` call fails with `depth_exceeded`, and the agent reports the limit instead of working around it. It cannot change the setting (there is no MCP tool for that).
4. In the app, in `Topics` mode, move a Smart Folder under `Input`. **Expected**: a dialog asks `Would you like to update your max Smart Folder depth setting to 3?`. Cancel leaves everything unchanged; confirm raises the limit and completes the move.
5. Check the setting. **Expected**: `memex settings get --vault "$VAULT" --key smart_folder_max_depth` now prints `"value":3`. Retry the agent's request from step 3: it succeeds. Set it back with `memex settings set --vault "$VAULT" --key smart_folder_max_depth --value 2`; **expected** the command succeeds and the limit applies to new nesting from then on.

## 8. Scheduled review with claude -p

1. Add one more quick entry, then run the same command a cron entry would:
   ```bash
   memex append --vault "$VAULT" "Last note: try a dash cooldown"
   claude -p "$(memex prompt review)" --allowedTools "mcp__memex" --mcp-config "$SCRATCH/mcp.json" --strict-mcp-config
   ```
2. **Expected**: with no prompts and no session, the command prints a short summary and exits 0. Today's chip in the app is green again and the topic note the agent used has an Activity entry.
3. Run `memex prompt capture` and `memex prompt review`. **Expected**: each prints the raw prompt text, no JSON.

## 9. Feedback and a Correction: the agent fixes the filing, replies and updates the Vault Guide

Needs the reviewed days from section 2, so the days are filed into topic notes. Use two topic notes from the review, and one block that sits in the first.

1. Find a block and where it is filed:
   ```bash
   memex filing --vault "$VAULT" --date 2026-09-05
   ```
   **Expected**: JSON with `topics` (each with its `topic_note_id`, `title` and `blocks`) and `not_filed`. Pick a block in one topic note (call it A) and a second topic note (B).
2. As the person, make a Correction: move the block from A to B, with a note saying why.
   ```bash
   memex excerpt move --vault "$VAULT" --date 2026-09-05 --block-id <block id> \
     --from-topic-note-id <id of A> --to-topic-note-id <id of B> --note "This is about B, not A"
   ```
   **Expected**: the command succeeds. In the app, B's Activity tab shows a Correction for it, open.
3. Leave a written comment about a filing the Correction does not fix. Choose an entry in a note's Activity tab, press `Comment`, and write `Keep sleep notes out of the Player Loop topic`. Or from the shell:
   ```bash
   memex feedback add --vault "$VAULT" --note-id <note id> --date 2026-09-05 --change-id <Activity entry id> --text "Keep sleep notes out of the Player Loop topic"
   ```
   **Expected**: the comment shows as open Feedback in Activity.
4. In the Claude Code session from section 2, run `/mcp__memex__review_daily_notes`.
5. **Expected**: the agent calls `get_vault_guide`, then `list_open_feedback`, before it takes any day, and works through the open Feedback oldest first. For the comment it fixes the filing it names (`remove_excerpt_block` plus `add_excerpt` for one block), and distills the lasting decision into the Vault Guide with `update_vault_guide`. It marks each item Handled with `resolve_feedback` and a one-line reply that says what it did or why it could not, and never quotes your text. It does not sweep older days for work the Feedback does not name.
6. Check the app. **Expected**: both Feedback rows read `Handled` with the agent's reply, the Correction is not undone, and the Vault Guide's Activity tab has a new entry from the agent. Check the text with `memex guide get --vault "$VAULT"`: **expected** it keeps its `## Framework` and `## Decisions` sections and holds the new decision in a short sentence, and `memex guide revisions --vault "$VAULT"` lists the text it replaced.

## 10. A comment about filing in a live Review session

1. In a new Claude Code session started the same way as section 2, run `/mcp__memex__review_daily_notes`. When the agent has finished, or while it works, type: `Sleep notes belong in the Sleep topic, not the Player Loop topic.`
2. **Expected**: the agent treats the comment as Feedback. It fixes the filing on the spot, records your words as you typed them with `record_feedback` (with a one-line reply), and, since the comment is lasting, updates the Vault Guide. Any change it makes outside marking a day reviewed is listed in the `changes` of the call.
3. In the app, open the topic note it changed and its Activity tab. **Expected**: an entry for the fix, and a Feedback row labelled `From chat` that reads `Handled`, with your sentence exactly as typed. It was Handled when it was stored, so it never shows as open.

## 11. After a Correction, a later review does not redo it

1. Take a block out of a topic note yourself, as in section 9 step 2 (or with `memex excerpt remove-block --vault "$VAULT" --topic-note-id <id> --date 2026-09-05 --block-id <block id>`), so the Correction names a block and a topic note.
2. Without editing that day, run `/mcp__memex__review_daily_notes` again in Claude Code. If the agent reports no day to review, that is the expected case here.
3. **Expected**: the agent works through the Correction as Feedback and marks it Handled. It does not re-file the block into the topic note you took it out of, and it does not re-add a topic note to a Smart Folder you took it out of. Check with `memex filing --vault "$VAULT" --date 2026-09-05`: the block is not back in that topic note.
4. Edit the block so that its text is clearly about another subject, and review once more. **Expected**: the block is filed where it now belongs, which is the agent's judgment, and the earlier Correction still shows in Activity.

## Clean up

Close the app's scratch vault tab, then `rm -rf "$SCRATCH"` (check `echo "$SCRATCH"` first: it must be the temporary directory from the Prereqs).

## What's intentionally not covered here

- Running against a model without MCP tool support, or Raycast AI chat itself (Raycast-style entry here means the `memex append` command a Raycast script would call).
- Claude Desktop scheduled tasks (the same prompt, set up in Claude Desktop; see `docs/daily-review.md`).
- Schema V4 to V5 upgrade of an existing vault (see the README upgrade note; try it on a duplicate of the vault directory first).
- Whole-vault Graph view and canvases (canvases are unchanged by this slice; see `docs/canvas-acceptance.md`).
