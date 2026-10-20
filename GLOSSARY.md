# Open Memex Glossary

Canonical language for the Open Memex vault, app, and MCP surface. Use these terms in code, docs, tool names, and agent prompts.

## Terminology

**Vault**:
A directory holding one knowledge base: `memex.db`, `objects/`, and `manifest.json`.

**Note**:
The single unit of content in a vault: a title, a markdown body, and frontmatter. Daily notes and topic notes are notes with a role, not separate types.

**Wikilink**:
A typed link between two notes written in a note body as `[[Title~kind|alias]]`. The only linking mechanism in the vault; the graph, backlinks, and canvas all render wikilinks.
_Avoid_: symlink, reference, edge

**Block**:
One paragraph, list item, or heading of a daily note, carrying a stable id that survives edits to its text. Block ids live in the vault database, not in the note body.
_Avoid_: chunk, span, line

**Transclusion**:
A `![[Title#^blockid]]` reference in a note body that renders the live text of another note's block or block range in place. The text is not copied.
_Avoid_: embed, copy, excerpt copy

**Excerpt**:
The block range of a daily note that a topic note transcludes.
_Avoid_: snippet, quote

**Daily note**:
The one note per calendar day the person types into. Its title is the ISO date, such as `2026-09-05`.
_Avoid_: journal, day page, log

**Topic note**:
A note about one subject that accumulates excerpts across days, maintained by the person's agent or created by the person.
_Avoid_: subject note, concept note, chunk

**Topics footer**:
The managed block at the bottom of a daily note, below a marker line, holding `[[Topic~about]]` links to every topic that holds an excerpt from that day. Everything above the marker belongs to the person.
_Avoid_: links section, related

**Review**:
An agent run that files a daily note's changed blocks into topic notes and Smart Folders, then marks the day reviewed.
_Avoid_: organize, process, sync

**Capture**:
An agent appending an observation the person typed to it onto today's daily note, then filing those blocks as a review would. The only agent write path into a daily note body, and append-only.
_Avoid_: dictation, quick add, inbox

**Reviewed**:
The state of a daily note once the agent has processed its current content into topic notes. A daily note edited after review is unreviewed again.
_Avoid_: organized, processed, synced

**Smart Folder**:
An agent-maintained grouping of topic notes by similarity. A topic note can belong to many Smart Folders, and Smart Folders can nest.
_Avoid_: folder, grouping, category, tag

**Pinned**:
A flag on a Smart Folder or on a topic's membership in a Smart Folder that the agent must not remove, rename, re-parent, or delete. Set automatically when the person creates or edits the thing, and toggleable by the person.
_Avoid_: locked, user-owned, protected

**Topics**:
The navigation mode that browses the vault by Smart Folder and topic note, as opposed to browsing by date.
_Avoid_: subjects, by subject

**Agent**:
The AI the person brings and connects over MCP, such as Claude, that organizes the vault. The app never calls a model itself.
_Avoid_: the AI, the model, background AI

**Graph view**:
A read-only, automatically laid out view of notes and the wikilinks between them, scoped to a Smart Folder, topic note, daily note, or the whole vault. Nothing about its layout is stored.
_Avoid_: spiderweb, canvas, map

**Canvas**:
A user-curated board where notes are placed as draggable nodes and wikilinks between placed notes render as labelled lines.

**Vault server**:
A `memex` process that owns the vaults in one vault root on its own disk and serves them over the network to apps and agents, through MCP over HTTP and the app API.
_Avoid_: sync server, cloud, backend, NAS mode

**Vault root**:
The directory on a vault server's disk whose subfolders are the vaults that server serves.

**Hosted vault**:
A vault the app opens by URL through a vault server.
_Avoid_: remote vault, shared vault, network vault, synced vault

**Local vault**:
A vault the app opens by directory path on the same machine.

**Access token**:
The one shared secret every client presents to a vault server.
_Avoid_: API key, password
