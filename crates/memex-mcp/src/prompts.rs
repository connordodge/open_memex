//! MCP prompts and the `memex prompt` texts.
//!
//! Architect ruling D18: each prompt's text exists exactly once, here. The MCP
//! prompts (`review_daily_notes`, `capture`) and `memex prompt review|capture`
//! all serve these constants unchanged.

use rmcp::model::{PromptMessage, PromptMessageRole};
use rmcp::{prompt, prompt_router};

use crate::tools::Memex;

/// The text of the `review_daily_notes` MCP prompt and `memex prompt review`.
pub const REVIEW_DAILY_NOTES: &str = r#"# Review daily notes

Review the person's Open Memex vault through the memex MCP tools. A review files each unreviewed daily note's new and changed blocks into topic notes as excerpts, links related topic notes, places topic notes in Smart Folders, and marks the day reviewed with a short record of what you changed. Work through the unreviewed days one at a time, oldest first.

## Ground rules

- Never rewrite, reorder, delete, summarise, clean up or merge the person's text, in a daily note or anywhere else. You file their blocks by reference with `add_excerpt`; you never copy their words into a topic note, never add text to a daily note during a review, and never write transclusion or Note footer syntax by hand. The server maintains the Note footer.
- Pinned Smart Folders and pinned memberships were set by the person. Respect pinned items exactly as step 6 says.
- If a tool returns an error, read its `code` and message and change what you send. Never repeat the same failing call unchanged.
- The Vault Guide is the one exception to the never-rewrite rule above: you may rewrite any of it, with `update_vault_guide`, as the Feedback section below says. Keep it short, about 200 lines.

## Feedback and the Vault Guide

The person tells you how you filed their notes in two ways: a comment they wrote, and a Correction, a change they made to your filing themselves. Both are Feedback. Work through the open Feedback on every run, even when no days are unreviewed, before you take a day in step 1.

1. Call `get_vault_guide`, read the Vault Guide and follow it when filing, in this section and in steps 1 to 8. It holds the vault's framework for filing, with the decisions behind it.
2. Call `list_open_feedback` and work through its items, oldest first. Each item is a comment or a Correction, with a `note_id`, a `day` and the person's `text`.
3. For each item, in this order:
   - Fix the filing a comment names, within the pinned rules of step 6. Call `get_day_filing` with the `date` to see where a day's blocks are filed. To move one block, call `remove_excerpt_block` (`topic_note_id`, `date`, `block_id`) and then `add_excerpt` for the topic note that should hold it.
   - If a Correction names a person-created topic note that is in no Smart Folder, place it with `add_to_smart_folder`, as step 6 says.
   - Treat the latest Correction per block as final. Never re-file a block into a topic note that the person took it out of. Never re-add a topic note to a Smart Folder that the person took it out of. Do neither unless the block's text has changed so much that it clearly belongs there now. There is no server block on this: it is your judgment.
   - If the item shows a lasting decision about how this vault is filed, distill it into the Vault Guide with `update_vault_guide`, passing the `version` from `get_vault_guide`, the whole new `content_md` and 1 to 3 `bullets`. Read the guide again before the next update.
   - Mark the item Handled with `resolve_feedback`, passing its `id`, a one-line reply saying what you did, or why you could not, and the `changes` you made. The reply never quotes or summarises the person's text. If `resolve_feedback` returns `not_found`, the person deleted that item: carry on with the next one.
4. Do not sweep older days for work the Feedback does not name, unless the Feedback asks you to. Fix what an item names, and leave the rest of the vault as it is.

During a session, when the person makes a comment about filing, treat it as Feedback. Fix it on the spot, record it word for word with `record_feedback` (`text`, and `note_id` and `date` when it is about one note or day) with a one-line `reply`, and if it is lasting, update the guide with `update_vault_guide`. A fix you make outside `mark_day_reviewed` goes in the `changes` of `record_feedback` or `resolve_feedback`, one entry for each note you touched.

## 1. Take the oldest unreviewed day

Call `list_unreviewed_days`. Each entry has a `date`, a `state` (`Unreviewed` or `Changed since review`), a `content_version` and a `reviewed_content_version`. If the list is empty, there are no unreviewed days: report the Feedback you worked through, and that there were no days to review, in one line, then stop. Otherwise take the oldest date (the list is sorted oldest first).

## 2. Fetch what changed

Call `get_daily_note_changes` with that date. Keep the `content_version` it returns: it is the version you mark reviewed in step 7. It lists three kinds of blocks, each with an `id`, a `source` and its `text`:

- `added`: blocks that are new since the last review. For a day never reviewed, every block is here.
- `changed`: blocks whose text changed since the last review, with their current text. A changed block may already be an excerpt in a topic note; an excerpt always shows the live text, so it needs no update. File it again only if its new text belongs to a topic note that does not hold it yet (use `search` on its text: a hit that comes through an excerpt is labelled `via` and the date, such as `via 2026-09-05`).
- `removed`: blocks the person deleted, with their last text. There is nothing to file for them; leave any excerpt of them as it is.

File blocks of every `source` (`person`, `agent` or `quick-entry`) the same way. Blocks that are not listed were filed by an earlier review; leave them alone.

## 3. Group the blocks by subject

Read the listed blocks in their order and group them by what they are about. Consecutive blocks about one subject become one excerpt. One block can belong to more than one topic note. A block that fits no subject worth a topic note can stay unfiled; it is still part of the reviewed day.

## 4. Find or create the topic note for each subject

Search before creating a topic note. For each subject, call `search` with a few words naming the subject and words from its blocks. Open likely hits with `get_note` and check that the note has `role: topic` in its frontmatter and is about the same subject. Prefer an existing topic note, even when its title is not the one you would have chosen.

Only when no topic note matches, create one with `create_note`, passing `role: topic`, a short title naming the subject (a noun phrase such as `Player Loop`), and `content_md` of one neutral sentence saying what the topic covers. That sentence describes the subject; it never restates or summarises the person's words. Never create a second topic note for a subject that already has one, and never create a daily note. If `create_note` fails with `title_conflict`, a note with that title exists: use it if it is a topic note about the same subject, otherwise choose a more specific title.

## 5. Add excerpts

For each topic note, call `add_excerpt` with its `topic_note_id`, the `date` and the `block_ids` to file there, in the order they appear in the day. The server writes the transclusion under that date's heading in the topic note, joins consecutive blocks into one range, and adds the topic note to the day's Note footer. Never add the same block to the same topic note twice.

## 6. Link topic notes and place them in Smart Folders

Link topics that reference each other. When two topic notes you touched in this run are clearly related to each other, call `add_link` from one to the other. Use the default `references` kind, or a more precise one such as `extends`, `contradicts` or `example-of`. Links go from topic note to topic note only: never from a daily note, and never from a note to itself. A link that already exists needs no second call.

Place every topic note you created in at least one Smart Folder, and any existing topic note you touched that is in none:

1. Call `get_vault_settings` once per run and read `smart_folder_max_depth`: the Smart Folder depth limit. A root Smart Folder has depth 1, its child depth 2, and so on. Stay within the depth limit: never create or move a Smart Folder deeper than it. You cannot raise it; only the person can.
2. Call `list_smart_folders` to see the tree: each Smart Folder's `depth`, `pinned` flag and members, and the topic notes that are in no Smart Folder.
3. Add the topic note to the best existing Smart Folder with `add_to_smart_folder`, passing `topic_note_id` and `smart_folder_id`. A topic note can belong to several Smart Folders at any level.
4. If none fits, create one with `create_smart_folder`, giving a short name and a `parent_id` only when the parent's depth is below the limit, then add the topic note to it. If a call fails with `depth_exceeded`, put the Smart Folder higher in the tree instead.

Respect pinned items:

- You may add topic notes to a pinned Smart Folder.
- Never rename, re-parent or delete a pinned Smart Folder, and never remove any topic note from it.
- Never remove a pinned membership. A topic note pinned in a Smart Folder stays a member of whatever that Smart Folder becomes.
- Unpinned Smart Folders and memberships are yours to change: rename, re-parent, merge, split or delete them with `update_smart_folder`, `remove_from_smart_folder` and `delete_smart_folder`, within the depth limit, when that clearly improves how topic notes are grouped. Deleting a Smart Folder never deletes topic notes. Do not reshuffle the tree on every run.
- If a call fails with `pinned_rule`, leave that item as it is and carry on.

## Tagging notes

Tag the notes you touch with tags the person already uses. Run this after step 6 and before step 7.

- Call `list_tags` once per run, before your first `tag_note`, and keep the result. It lists the tags the person has written in their notes. If it lists no tags, apply none and skip the rest of this section.
- Call `tag_note` with a `note_id` and a tag name, only for a tag that `list_tags` lists. Never invent a tag name.
- Tag only the day's daily note and the topic notes you touched in this run, and only when the tag fits the note as a whole, not one block of it. Tag no other note, even one that looks related.
- Never add text to a daily note to tag it: `tag_note` writes the tag's line in the Note footer, and the person's text is left alone. Never write a `#tag` into a note body.
- If `tag_note` fails, read its `code`, do not retry the same call, and carry on with the next note or tag:
  - `unknown_tag`: the tag is not in the vocabulary. Leave that tag off.
  - `tag_removed`: the person took that tag off this note, so a removed tag stays off. Leave that tag off.
  - `guide_rule`: the note is the Vault Guide, which you never tag. Leave that note alone.
- Record each tag you applied in step 7.

## 7. Mark the day reviewed

Call `mark_day_reviewed` with the `date`, `version` set to the `content_version` you fetched in step 2 (not a newer one), and `changes`: a list of `{note_id, bullets}` entries, one entry per note you touched in this run.

Change-entry rules (the server rejects the whole call if any one is broken):

- One entry for each touched note: every topic note you created, added an excerpt to, linked from, or added to a Smart Folder, plus an entry for the daily note itself. The daily note's entry is always required, even when nothing needed filing (for example `Nothing new to file`).
- A note you touched only by tagging needs its entry too: tagging alone counts as touching it. Each tag you applied to a note gets a bullet in that note's entry, such as `Tagged #pricing`.
- Each entry has 1 to 3 bullets.
- Each bullet is one line of plain markdown, at most 200 characters, with no newline and no leading `- ` (the app adds the bullet marker).
- Bullets say what you did, for example `Filed 2 blocks into Player Loop` or `Linked to Level Design (extends)`. They never quote or summarise the person's text.

If the call fails with `change_entries_invalid`, fix the entries and call it again. If it fails with `review_stale`, the person edited the day while you worked: go back to step 2 for the same date, fetch the changes again, file only what you have not filed in this run, and mark the day reviewed with the new `content_version`.

## 8. Repeat

Repeat from step 1 until `list_unreviewed_days` reports no unreviewed days. If a day still cannot be marked reviewed after you have acted on its errors, leave it, take the next oldest day, and name it in your report. When you finish, reply with a short report: the days you reviewed and the topic notes you created or added excerpts to.
"#;

/// The text of the `capture` MCP prompt and `memex prompt capture`.
pub const CAPTURE: &str = r#"# Capture

For the rest of this session, each message the person sends you is an observation to capture into their Open Memex vault through the memex MCP tools. Do not answer it, discuss it or ask about it: capture it, file it, and reply in one line. Only a message that clearly speaks to you about this capture session itself (such as `stop capturing`) is not an observation.

Never rewrite, reorder, delete, summarise, clean up or merge the person's text: not to fix spelling, not to combine it with an earlier observation, not to turn it into prose. Each observation lands exactly as typed.

At the start of the session, before the first observation, call `get_vault_guide` and read the Vault Guide: the vault's framework for filing, with the decisions behind it. Follow it when filing. Do not write the guide.

For each message:

1. Append it verbatim to today's daily note with `append_to_daily_note`, passing the whole message as `text` and no `date`; the server uses today and creates today's daily note if it does not exist yet. Verbatim means the same words, spelling, punctuation, line breaks and order. Append each message in its own call. The call returns the new `block_ids`, the day's `date` and `note_id`, the new `content_version`, the note's `version`, and `prior_state`: the day's review state just before your append.

2. File the returned blocks into topic notes. For the blocks in `block_ids`, find the topic note each belongs to: call `search` with words from the observation and confirm likely hits with `get_note` (a topic note has `role: topic`). Search before creating a topic note; only when none matches, create one with `create_note`, passing `role: topic`, a short title naming the subject and `content_md` of one neutral sentence saying what the topic covers. Then call `add_excerpt` with the `topic_note_id`, the returned `date` and the `block_ids` to file there. Place a topic note you created in a Smart Folder with `add_to_smart_folder`, after reading the depth limit (`smart_folder_max_depth` from `get_vault_settings`) and the tree (`list_smart_folders`); create a Smart Folder with `create_smart_folder` only when none fits, within the depth limit. Never remove, rename, re-parent or delete anything pinned. A block that fits no topic note can stay unfiled.

3. Mark the day reviewed only if the returned `prior_state` was `Reviewed`. Then nothing else on the day is waiting to be filed, so call `mark_day_reviewed` with the returned `date`, `version` set to the returned content version (`content_version`, not the note's `version`), and `changes`: one `{note_id, bullets}` entry for each note you touched (each topic note you created, filed into or placed in a Smart Folder, plus an entry for the daily note itself). Each entry has 1 to 3 bullets; each bullet is one line of at most 200 characters with no leading `- `, saying what you did, never quoting or summarising the person's text.

4. Otherwise run a full review of the day instead. If `prior_state` was `Unreviewed` or `Changed since review`, the day holds earlier text that no review has filed, so marking it reviewed with your version would hide that text. Likewise, if the version check fails (`mark_day_reviewed` returns `review_stale` because the person edited the day meanwhile), run a full review. A full review of the day: call `get_daily_note_changes` for the returned `date`; file every `added` and `changed` block it lists that you have not already filed in step 2, the same way as step 2 (search before creating, never the same block twice in one topic note); then call `mark_day_reviewed` with the `content_version` that `get_daily_note_changes` returned and one entry for each touched note, including the daily note itself. If that fails with `review_stale` again, repeat the full review.

5. Reply in one line saying where the observation went: the day it was added to and the topic notes it was filed under, for example `Added to 2026-10-03, filed under Player Loop and Level Design.` If it went into no topic note, say it was added to today's daily note only. If a step failed, say which in that same line.

Tagging the notes you touch, before step 3 marks the day reviewed:

- Call `list_tags` once per session, before your first `tag_note`, and keep the result. It lists the tags the person has written in their notes. If it lists no tags, apply none.
- Call `tag_note` with a `note_id` and a tag name, only for a tag that `list_tags` lists, on a topic note you touched or on today's daily note, and only when the tag fits the note as a whole. Tag no other note. Never invent a tag name.
- Never write a `#tag` into a note body: `tag_note` writes the tag's line in the Note footer and leaves the person's text alone.
- If `tag_note` fails, read its `code`, do not retry the same call, and carry on:
  - `unknown_tag`: the tag is not in the vocabulary. Leave that tag off.
  - `tag_removed`: the person took that tag off this note, so a removed tag stays off. Leave that tag off.
  - `guide_rule`: the note is the Vault Guide, which you never tag. Leave that note alone.
- Each tag you applied gets a bullet in that note's change entry, such as `Tagged #pricing`. A note touched only by tagging needs its entry too.
"#;

/// The single user message a prompt's text is served as.
fn user_message(text: &str) -> Vec<PromptMessage> {
    vec![PromptMessage::new_text(PromptMessageRole::User, text)]
}

#[prompt_router(vis = "pub(crate)")]
impl Memex {
    #[prompt(
        name = "review_daily_notes",
        description = "Review every unreviewed daily note, oldest first: file new and changed \
                       blocks into topic notes as excerpts, link related topic notes, place them \
                       in Smart Folders, and mark each day reviewed."
    )]
    fn review_daily_notes_prompt(&self) -> Vec<PromptMessage> {
        user_message(REVIEW_DAILY_NOTES)
    }

    #[prompt(
        name = "capture",
        description = "Treat each message as an observation: append it verbatim to today's daily \
                       note, file it into topic notes, and reply in one line with where it went."
    )]
    fn capture_prompt(&self) -> Vec<PromptMessage> {
        user_message(CAPTURE)
    }
}
