//! Tool and prompt metadata: the one static table behind the Agents sheet's
//! Tools tab (`memex tools`, `GET /api/v1/tools`) and the activity hook's
//! "is this a write" check (ruling D11).
//!
//! Every tool `Memex::routers()` registers has exactly one row here, and every
//! registered prompt has one too. `tests/tool_meta.rs` fails on a tool added
//! without a row or on a stale row.

/// A Tools tab section, in display order (Spec #394 requirement 34).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub enum Group {
    Notes,
    Daily,
    Folders,
    Tags,
    Feedback,
    Canvas,
}

impl Group {
    /// The stable wire id, such as `notes`.
    pub fn id(self) -> &'static str {
        match self {
            Group::Notes => "notes",
            Group::Daily => "daily",
            Group::Folders => "folders",
            Group::Tags => "tags",
            Group::Feedback => "feedback",
            Group::Canvas => "canvas",
        }
    }

    /// The section label shown in the Tools tab, such as `Notes and search`.
    pub fn label(self) -> &'static str {
        match self {
            Group::Notes => "Notes and search",
            Group::Daily => "Daily review",
            Group::Folders => "Smart Folders",
            Group::Tags => "Tags and Note footer",
            Group::Feedback => "Feedback and Vault Guide",
            Group::Canvas => "Canvases",
        }
    }
}

/// Every group, in display order.
pub fn groups() -> &'static [Group] {
    &[
        Group::Notes,
        Group::Daily,
        Group::Folders,
        Group::Tags,
        Group::Feedback,
        Group::Canvas,
    ]
}

/// One registered MCP tool.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ToolMeta {
    pub name: &'static str,
    /// One line of plain text, at most 100 characters, written for the Tools
    /// list (not cut from the MCP description).
    pub summary: &'static str,
    pub group: Group,
    /// True when the tool changes the vault.
    pub writes: bool,
}

/// One registered MCP prompt.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct PromptMeta {
    pub name: &'static str,
    /// One line of plain text, at most 100 characters.
    pub summary: &'static str,
}

const fn read(name: &'static str, group: Group, summary: &'static str) -> ToolMeta {
    ToolMeta {
        name,
        summary,
        group,
        writes: false,
    }
}

const fn write(name: &'static str, group: Group, summary: &'static str) -> ToolMeta {
    ToolMeta {
        name,
        summary,
        group,
        writes: true,
    }
}

/// Every tool row, by group, in the Spec #394 requirement 34 order within each.
static TOOLS: [ToolMeta; 40] = [
    // Notes and search
    read(
        "search",
        Group::Notes,
        "Finds notes by keyword or meaning and returns the best-matching passages.",
    ),
    read(
        "get_note",
        Group::Notes,
        "Reads one note in full, optionally with its outgoing links and backlinks.",
    ),
    read(
        "neighbors",
        Group::Notes,
        "Lists the notes linked to a note, up to a few hops away in either direction.",
    ),
    write(
        "create_note",
        Group::Notes,
        "Creates a new note, tagged agent-authored and inbox for you to review.",
    ),
    write(
        "edit_note",
        Group::Notes,
        "Edits a note's text by exact find-and-replace or a full rewrite, unless it is read-only for agents.",
    ),
    write(
        "add_link",
        Group::Notes,
        "Adds a wikilink from one note to another, as a reference or a named kind.",
    ),
    write(
        "update_link",
        Group::Notes,
        "Changes the kind or label of an existing wikilink.",
    ),
    write(
        "add_attachment",
        Group::Notes,
        "Stores a file in the vault and returns the markdown to place in a note.",
    ),
    read(
        "get_attachment",
        Group::Notes,
        "Reads an attachment: an image, a text file's text, or its details.",
    ),
    // Daily review
    read(
        "list_unreviewed_days",
        Group::Daily,
        "Lists the daily notes still waiting for a review, oldest first.",
    ),
    read(
        "get_daily_note_changes",
        Group::Daily,
        "Shows the blocks added, changed or removed in a daily note since its last review.",
    ),
    read(
        "get_day_filing",
        Group::Daily,
        "Shows which topic notes hold each block of a daily note, and which blocks are unfiled.",
    ),
    write(
        "append_to_daily_note",
        Group::Daily,
        "Adds text verbatim to the end of a daily note, creating the day if needed.",
    ),
    write(
        "add_excerpt",
        Group::Daily,
        "Files blocks of a daily note into a topic note as an excerpt.",
    ),
    write(
        "remove_excerpt",
        Group::Daily,
        "Takes one excerpt of a day back out of a topic note.",
    ),
    write(
        "remove_excerpt_block",
        Group::Daily,
        "Takes a single block of a day out of a topic note, splitting the excerpt around it.",
    ),
    write(
        "mark_day_reviewed",
        Group::Daily,
        "Marks a daily note reviewed and records what the review changed.",
    ),
    // Smart Folders
    read(
        "list_smart_folders",
        Group::Folders,
        "Lists every Smart Folder with its topic notes, plus the notes in no folder.",
    ),
    write(
        "create_smart_folder",
        Group::Folders,
        "Creates a Smart Folder at the top level or inside another folder.",
    ),
    write(
        "update_smart_folder",
        Group::Folders,
        "Renames a Smart Folder or moves it to a new parent.",
    ),
    write(
        "delete_smart_folder",
        Group::Folders,
        "Deletes a Smart Folder; its subfolders move up and no note is deleted.",
    ),
    write(
        "add_to_smart_folder",
        Group::Folders,
        "Puts a topic note in a Smart Folder.",
    ),
    write(
        "remove_from_smart_folder",
        Group::Folders,
        "Takes a topic note out of a Smart Folder.",
    ),
    // Tags and Note footer
    read(
        "list_tags",
        Group::Tags,
        "Lists the tags you have written in notes, with how many notes carry each.",
    ),
    write(
        "tag_note",
        Group::Tags,
        "Applies one of your tags to a note and adds it to the Note footer.",
    ),
    write(
        "untag_note",
        Group::Tags,
        "Removes a tag an agent applied to a note, along with its Note footer line.",
    ),
    write(
        "add_footer_topic",
        Group::Tags,
        "Adds a topic note chip to a note's Note footer.",
    ),
    // Feedback and Vault Guide
    read(
        "list_open_feedback",
        Group::Feedback,
        "Lists your open comments and corrections on the agent's filing, oldest first.",
    ),
    write(
        "record_feedback",
        Group::Feedback,
        "Saves feedback you gave in chat about the filing, already marked handled.",
    ),
    write(
        "resolve_feedback",
        Group::Feedback,
        "Marks one piece of open feedback handled, with a one-line reply.",
    ),
    read(
        "get_vault_guide",
        Group::Feedback,
        "Reads the Vault Guide, the framework and decisions the agent files by.",
    ),
    write(
        "update_vault_guide",
        Group::Feedback,
        "Rewrites the Vault Guide and notes what changed.",
    ),
    read(
        "get_vault_settings",
        Group::Feedback,
        "Reads the vault settings agents work within, such as folder depth and link kinds.",
    ),
    // Canvases
    read(
        "list_canvases",
        Group::Canvas,
        "Lists every canvas, most recently updated first.",
    ),
    read(
        "get_canvas",
        Group::Canvas,
        "Reads a canvas with its placed notes, their positions and the links between them.",
    ),
    write(
        "create_canvas",
        Group::Canvas,
        "Creates a new, empty canvas with a unique title.",
    ),
    write(
        "add_to_canvas",
        Group::Canvas,
        "Places a note on a canvas at a position.",
    ),
    write(
        "remove_from_canvas",
        Group::Canvas,
        "Takes a note off a canvas; the note itself is untouched.",
    ),
    write(
        "move_node",
        Group::Canvas,
        "Moves a note to a new position on its canvas.",
    ),
    write(
        "delete_canvas",
        Group::Canvas,
        "Deletes a canvas; the notes on it are untouched.",
    ),
];

/// Every prompt row.
static PROMPTS: [PromptMeta; 2] = [
    PromptMeta {
        name: "review_daily_notes",
        summary: "Reviews each unreviewed daily note: files blocks, links topics, marks the day reviewed.",
    },
    PromptMeta {
        name: "capture",
        summary: "Saves each message to today's daily note, files it and says where it went.",
    },
];

/// Every tool row.
pub fn tools() -> &'static [ToolMeta] {
    &TOOLS
}

/// Every prompt row.
pub fn prompts() -> &'static [PromptMeta] {
    &PROMPTS
}

/// The row for the tool named `name`, if any. The match is exact and
/// case-sensitive.
pub fn tool(name: &str) -> Option<&'static ToolMeta> {
    TOOLS.iter().find(|row| row.name == name)
}

/// The row for the prompt named `name`, if any. The match is exact and
/// case-sensitive.
pub fn prompt(name: &str) -> Option<&'static PromptMeta> {
    PROMPTS.iter().find(|row| row.name == name)
}

/// True only for a registered tool that changes the vault.
pub fn is_write(name: &str) -> bool {
    tool(name).is_some_and(|row| row.writes)
}

/// Write tools the activity hook never logs, because no note changes:
/// `add_attachment` only stores a file (Spec #123 R18).
const UNLOGGED_WRITES: [&str; 1] = ["add_attachment"];

/// True for a write tool whose calls the activity hook logs: every
/// [`is_write`] tool except `add_attachment`. The hook decides "is this a
/// logged write" through this function alone.
pub fn is_logged(name: &str) -> bool {
    is_write(name) && !UNLOGGED_WRITES.contains(&name)
}

/// The names of every write tool.
pub fn write_tools() -> Vec<&'static str> {
    TOOLS
        .iter()
        .filter(|row| row.writes)
        .map(|row| row.name)
        .collect()
}
