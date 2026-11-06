# Tags in Open Memex

A tag labels a whole note. You write `#work` anywhere in a note and the note is tagged `work`. You can then browse every note with that tag in the sidebar, and Review can tag the notes it touches, using only tags you already use.

Tags are separate from [Topic notes](daily-review.md) and Smart Folders. A topic is a note you link to; a tag is a label on a note.

This doc is the user-facing reference.

## Writing a tag

Type `#` followed by a name, anywhere in a note's text:

```markdown
Went for a #work lunch with the pricing team.
```

The whole note is now tagged `work`, not just that line. Your text stays exactly as you typed it. The tag is kept in step with your text every time you save:

- Typing a new `#name` adds the tag.
- Deleting the `#name` removes the tag.
- Writing it as `#Work` or `#WORK` is the same tag as `#work`. Names are stored in lowercase, and your text keeps the capitals you typed.

A tag in your text is the source of truth. Nothing else adds or removes it behind your back.

In the editor a `#tag` shows in a quieter colour, and in a soft highlight while your cursor is inside it.

## What counts as a tag

A tag is a `#` followed by a name:

- The `#` must start a line, or come right after a space, a tab, or an opening bracket or quote: `(` `[` `{` `"` `'`.
- The name starts with a letter (any language), then continues with letters, accents, digits, `-` or `_`.
- A trailing `-` or `_` isn't part of the name: `#plan-` is the tag `plan`.
- Tags are flat. A `/` doesn't make a hierarchy.

Examples:

| You write | Tags found |
|---|---|
| `#work #Work` | `work` (once) |
| `#q3-plan #résumé` | `q3-plan`, `résumé` |
| `see (#memex)` | `memex` |
| `#work/pricing` | `work`. The `/pricing` is plain text |
| `#fff` | `fff`. A colour code looks like a tag, and that is accepted. Edit the text to remove it |

### What is not a tag

| You write | Why |
|---|---|
| `#123` | A name must start with a letter |
| `a#b` | The `#` must start a line or follow a space or an opening bracket or quote |
| `` `#code` `` and fenced code blocks | Code is never scanned |
| `https://example.com/page#section` | URLs are never scanned |
| `[[Note #1]]` and `![[2026-09-05#^b7k2m9]]` | Wikilinks and transclusion tokens are never scanned |
| `[a link](page#part)` | Markdown links are never scanned |
| `# Heading` | A `#` followed by a space is a heading |

A heading's own text can hold tags: `## Plan #work` tags the note `work`.

Other things to know:

- Frontmatter isn't scanned. A `tags:` line in frontmatter is not indexed.
- A tag inside an excerpt you've filed into a topic note doesn't tag that topic note. It still looks like a tag there, and clicking it works.
- The [Vault Guide](#the-vault-guide) is never scanned.
- A note an agent writes with `create_note` isn't scanned for `#name`, so an agent can't add to your tags by writing one. The next time you save that note yourself, it is scanned.
- Writing `#x` on a note that already has `x` in its footer (see [The Note footer](#the-note-footer)) leaves one tag. It's now a tag in your text: its footer entry goes, and if you had removed an agent's `x` from that note earlier, that no longer blocks the agent (see [Removing a tag](#removing-a-tag)). Deleting the text later removes the tag.

## The `#` type-ahead

Typing `#` opens a list of your existing tags, in the same style as the `[[` list for wikilinks.

- The list shows up to 8 tags. Each row has a hash icon and, on the right, how many notes carry the tag.
- The first row is selected. ↑ and ↓ move, Enter or Tab accepts, Esc closes.
- Matching is the same as for `[[`: tags that start with what you typed come first, then tags that contain it, then tags with your letters in order. `prc` finds `pricing`.
- Accepting a tag replaces what you typed with `#name` and a space.
- At the start of a line the list opens only after the first letter (`#p`), so a bare `#` or `# ` (a heading) shows nothing. Elsewhere a bare `#` opens the list, with your most-used tags first.
- `##` to `######` (headings) never open it.
- It doesn't open where a `#` can't start a tag, such as inside code, a URL or a link.
- The list holds tags you've already written. To make a new tag, just type it. When your text doesn't match an existing tag, the last row offers the name as new. Enter on a name you typed in full, or on that row, just starts a new line and keeps your text as typed. Tab accepts it.
- System tags (below) aren't offered.

The `[[` list is unchanged.

## Tags mode

The sidebar switch is now `Days | Topics | Tags`. Open `Tags` to browse. Open Memex remembers the mode for each vault, like the other two.

- Every tag is listed alphabetically as `#work` with its note count.
- Click a tag to expand it. Its notes are listed with the most recently updated first. Each row shows the note's title and, under it, the first line of your text that holds the tag, trimmed and without its list marker. A note that has the tag only in its footer shows just the title.
- The note you have open is marked as active.
- Click a note row to go to that note.
- Long names and lines are cut off to fit the sidebar.
- At the bottom, a collapsed `System` group lists the system tags.
- With no tags yet, the pane says so and shows how to make one. If the list can't be read, it shows the same empty state the Topics pane does.
- The list updates when the vault changes, the same way the Topics pane does.

### System tags

`inbox` and `agent-authored` are system tags. They're quiet: they don't appear in a note's footer or header, you can't remove them with the ×, and they aren't offered by the type-ahead or counted in your tags. They're only listed in the `System` group. If you write `#inbox` in your own text, clicking it opens Tags mode with the `System` group expanded.

## Clicking a tag

Clicking a tag takes you to Tags mode with that tag expanded and scrolled into view. You can click a tag in:

- **A note's text.** Cmd+click works anywhere. A plain click works on a line where the markup is hidden, that is, a line your cursor isn't on. On the line your cursor is on, a plain click only moves the cursor. Hold Cmd to see the underline on tags you can open.
- **The meta rail** at the top of a note, which lists every tag on the note (system tags excepted). It is read-only.
- **The footer's Tags row.**
- **An excerpt in a topic note.**

Clicking a tag changes the sidebar and opens no new tab.

## The Note footer

Every note can have a Note footer: a block at the bottom, below the `<!-- memex:topics -->` marker, kept by the server. (It used to be called the Topics footer. The marker and the `memex footer` command keep their names, so no note needs rewriting.)

The footer has up to two rows:

- **Topics:** the topic notes linked to this note, as chips. Click one to open that topic note. Chips are never added automatically. You add one with `memex footer add --note-id <note> --topic-note-id <topic>`; the target must be a topic note, and a note can't chip itself. There's no add-chip button in the app.
- **Tags:** every tag on the note that isn't written in its text, whoever applied it (Review, `memex add --tags`, `memex tag add`). It's plain text, with no label saying who added it.

A row with nothing in it is left out, and a note with both rows empty shows no footer. A note with no footer content has no marker in its file either: the first item adds it, and removing the last removes it and leaves your text as it was.

Your text is everything above the marker. The footer is rebuilt from the note's tags and topics, never from text. So in Source mode you can see the marker and the lines below it, but a footer line you type there isn't kept, and a `#x` typed below the marker doesn't become a tag. Saving never brings back a tag you removed.

A daily note keeps its marker as before. Other notes get one only when they have footer content. A marker line inside a fenced code block, on a note that isn't a daily note, is just text.

### The Vault Guide

A note with `role: guide` (the Vault Guide) has no Note footer, is not scanned for tags, and can't be tagged by the agent, the CLI or the footer commands. It adds nothing to your tags. A note that becomes `role: guide` loses its tags and footer when it's saved.

## Removing a tag

Hover over a tag in the footer's Tags row, or move keyboard focus to it, and a × appears. Click it, or press Enter or Space on it, to remove the tag from that note. The × is labelled `Remove tag <name>` for screen readers.

- The tag stays visible until the removal has been written, then leaves the row and the footer redraws. The open note picks up the new version, so your next save doesn't conflict.
- Your text isn't touched. The note's review state doesn't change either.
- If the removal fails, for example because a hosted vault's server can't be reached, the tag stays and an error shows under the row. A tag that was already gone counts as removed.
- A tag written in your text has no ×. Delete the text to remove it. Deleting your own `#tag` is ordinary editing.
- There's no undo and no replace. To replace a tag, remove it, then write your own.
- System tags have no ×.

### A removed agent tag stays removed

If you remove a tag that Review or Capture applied, Open Memex records it. From then on the agent can't apply that tag to that note again: its attempt is refused with `tag_removed`. The block is per note. It ends when you write `#tag` in that note's text, or add it yourself with `memex tag add`. Removing a tag you added yourself (with `memex add --tags` or `memex tag add`), or a system tag, records nothing.

## What Review does with tags

Review (and Capture) can tag the notes they touch in a run. That means the day's daily note and the topic notes they file into, and no other note. Any other note is tagged only when you ask the agent directly.

- **Only your vocabulary.** The agent reads the list of tags you've written as `#name` in a note's text, and may apply only those. It can't invent a tag, and tags that exist only in a footer don't count as vocabulary.
- **No tags, no tagging.** On a vault where you've written no `#tag`, Review applies none.
- **Footer only.** A tag from Review goes in the footer's Tags row. It never writes anything into your text.
- **Listed in the change entry.** Each tag applied is a bullet in that note's entry in the day's review, such as `Tagged #pricing`.
- **Removed means removed.** A tag you've removed from a note (above) is not applied to it again.

Everything else about Review is as described in [daily-review.md](daily-review.md).

## From the command line: `memex tag`

```bash
memex tag add --vault V --note-id N --tag T   # add a tag to a note
memex tag rm  --vault V --note-id N --tag T   # remove a tag from a note
memex tag ls  --vault V                       # every tag, with note counts
memex tag ls  --vault V --note-id N           # one note's tags and where each came from
memex ls --tag T                              # notes that carry a tag
```

Each command prints one line of JSON.

- **`memex tag add`** adds a tag to any note except the Vault Guide. The tag isn't written in the note's text: it's a tag you applied, so it shows in the footer's Tags row. The name must follow the rules above (a leading `#` is fine, and capitals are lowercased). Adding a tag also ends any block left by an earlier removal of that tag from that note. A note that already has the tag is left alone.
- **`memex tag rm`** removes a tag from a note. If an agent applied it, the removal is recorded and blocks the agent, as for the ×. A tag you added yourself, or a system tag, goes without a record. If the tag is written in the note's text, the command fails and tells you to delete the text. If the note doesn't have the tag, it reports `removed: false`.
- **`memex tag ls`** lists every tag with its note count, system tags included and marked. With `--note-id` it lists one note's tags and their origin: `body` (written in the text), `agent` or `person`.
- **`memex add --tags`** gives a new note tags. They're yours (not the agent's), and they show in the footer.

`memex footer add` takes a topic note id for any note's footer; `--daily-note-id` still works as another name for `--note-id`.

A hosted vault has the same actions through the server. The app uses them for the × and for Tags mode.

## When you first open an existing vault

Upgrading reads each note's text once and turns the `#name`s already there into tags. No note text, version or modified time changes, and no day goes back to unreviewed. Until the vault is upgraded, the app shows its usual out-of-date vault message. Try the upgrade on a copy of your vault first.

Tags that were already stored stay as stored, even if they aren't lowercase or don't follow the rules above. `inbox` and `agent-authored` become system tags. A `Work` added from the command line before and a `#work` you type now show as two tags in Tags mode.

Because the scan reads any `#word`, it can tag things like `#fff` in old notes. Edit the text and the tag goes.

## Limits (v1)

- No renaming or merging a tag across the vault.
- No nested tags.
- Typing `#tag` in the sidebar search isn't supported.
- Names aren't Unicode-normalised, so `résumé` typed as one character and as `e` plus an accent are two tags. Mac keyboards produce the one-character form.
- No tag colours or sort options.
