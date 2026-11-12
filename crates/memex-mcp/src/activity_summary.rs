//! The one-line summary of an agent's MCP write call, for the agent activity
//! log (Spec #390 reqs 8-10). A pure function: no I/O, no vault.

use serde_json::Value;

/// Names the call may destroy or change, read by the caller before the tool
/// runs.
#[derive(Debug, Default)]
pub struct PreSnapshot {
    /// `update_smart_folder` (old name), `delete_smart_folder`.
    pub folder_name: Option<String>,
    /// `update_smart_folder` (old parent id), to tell "moved".
    pub folder_parent: Option<String>,
    /// `delete_canvas`.
    pub canvas_title: Option<String>,
    /// `update_link`.
    pub link_from_title: Option<String>,
    /// `update_link`.
    pub link_to_title: Option<String>,
}

/// Title lookups after the call, for names neither params nor result carry.
pub trait TitleLookup {
    fn note_title(&self, note_id: &str) -> Option<String>;
    fn folder_name(&self, folder_id: &str) -> Option<String>;
    fn canvas_title(&self, canvas_id: &str) -> Option<String>;
}

/// One logged line and the main note the call touched.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Summary {
    pub text: String,
    pub note_id: Option<String>,
}

/// The write tools this builder summarizes (Spec #390 req 8).
pub const WRITE_TOOLS: [&str; 24] = [
    "create_note",
    "add_excerpt",
    "remove_excerpt",
    "remove_excerpt_block",
    "add_footer_topic",
    "add_link",
    "update_link",
    "create_smart_folder",
    "update_smart_folder",
    "delete_smart_folder",
    "add_to_smart_folder",
    "remove_from_smart_folder",
    "tag_note",
    "untag_note",
    "append_to_daily_note",
    "mark_day_reviewed",
    "create_canvas",
    "delete_canvas",
    "add_to_canvas",
    "move_node",
    "remove_from_canvas",
    "update_vault_guide",
    "record_feedback",
    "resolve_feedback",
];

/// The longest a title or name may be before it is cut.
const MAX_TITLE_CHARS: usize = 40;
/// The longest a summary line may be before it is cut.
const MAX_SUMMARY_CHARS: usize = 120;
/// What stands in for a title, name or date no source can supply (for example
/// a note deleted since the call).
const UNKNOWN: &str = "(unknown)";

/// The summary of one call, or `None` when nothing is logged: the result
/// carries a top-level `error` key, the tool's "wrote nothing" signal holds,
/// or the tool is not one of [`WRITE_TOOLS`].
pub fn summarize(
    tool: &str,
    params: &Value,
    pre: &PreSnapshot,
    result: &Value,
    titles: &dyn TitleLookup,
) -> Option<Summary> {
    if result.get("error").is_some() {
        return None;
    }
    let cx = Cx {
        params,
        pre,
        result,
        titles,
    };
    let (text, note_id) = cx.build(tool)?;
    Some(Summary {
        text: cut(&one_line(&text), MAX_SUMMARY_CHARS),
        note_id,
    })
}

/// The inputs of one call.
struct Cx<'a> {
    params: &'a Value,
    pre: &'a PreSnapshot,
    result: &'a Value,
    titles: &'a dyn TitleLookup,
}

impl Cx<'_> {
    /// The line (before the whole-line cut) and `note_id` of `tool`'s call.
    fn build(&self, tool: &str) -> Option<(String, Option<String>)> {
        let p = |key: &str| str_of(self.params, key);
        let r = |key: &str| str_of(self.result, key);
        let (text, note_id) = match tool {
            "create_note" => {
                let title = match p("title") {
                    Some(title) => title.to_string(),
                    None => self.note(r("note_id")),
                };
                let verb = match p("role") {
                    Some("topic") => "created topic",
                    Some("daily") => "created daily",
                    _ => "created",
                };
                (format!("{verb} {}", title_of(&title)), owned(r("note_id")))
            }
            "add_excerpt" => {
                let n = len_of(self.result, "filed_block_ids");
                if n == 0 {
                    return None;
                }
                let topic = self.note(p("topic_note_id"));
                (
                    format!("filed {} → {}", blocks(n), title_of(&topic)),
                    owned(p("topic_note_id")),
                )
            }
            "remove_excerpt" => {
                let n = self
                    .result
                    .get("removed_count")
                    .and_then(Value::as_u64)
                    .unwrap_or(0);
                if n == 0 {
                    return None;
                }
                let topic = self.note(p("topic_note_id"));
                (
                    format!("unfiled {} from {}", blocks(n), title_of(&topic)),
                    owned(p("topic_note_id")),
                )
            }
            "remove_excerpt_block" => {
                self.wrote("removed")?;
                let topic = self.note(p("topic_note_id"));
                (
                    format!("unfiled 1 block from {}", title_of(&topic)),
                    owned(p("topic_note_id")),
                )
            }
            "add_footer_topic" => {
                self.wrote("changed")?;
                let topic = self.note(p("topic_note_id"));
                let note = self.note(p("note_id"));
                (
                    format!("added {} to {} footer", title_of(&topic), title_of(&note)),
                    owned(p("note_id")),
                )
            }
            "add_link" => {
                if self.result.get("was_existing").and_then(Value::as_bool) == Some(true) {
                    return None;
                }
                let from = self.note(p("from_id"));
                let to = self.note(p("to_id"));
                let suffix = match r("kind") {
                    Some("references") | None => String::new(),
                    Some(kind) => format!(" ({kind})"),
                };
                (
                    format!("linked {} → {}{suffix}", title_of(&from), title_of(&to)),
                    owned(p("from_id")),
                )
            }
            "update_link" => {
                self.wrote("changed")?;
                let from = or_unknown(self.pre.link_from_title.as_deref());
                let to = or_unknown(self.pre.link_to_title.as_deref());
                (
                    format!("updated link {} → {}", title_of(from), title_of(to)),
                    owned(r("from_note_id")),
                )
            }
            "create_smart_folder" => (
                format!("created folder {}", title_of(or_unknown(r("name")))),
                None,
            ),
            "update_smart_folder" => {
                self.wrote("changed")?;
                (self.folder_update()?, None)
            }
            "delete_smart_folder" => (
                format!(
                    "deleted folder {}",
                    title_of(or_unknown(self.pre.folder_name.as_deref()))
                ),
                None,
            ),
            "add_to_smart_folder" => {
                self.wrote("added")?;
                let topic = self.note(p("topic_note_id"));
                let folder = self.folder(p("smart_folder_id"));
                (
                    format!("added {} to {}", title_of(&topic), title_of(&folder)),
                    owned(p("topic_note_id")),
                )
            }
            "remove_from_smart_folder" => {
                self.wrote("removed")?;
                let topic = self.note(p("topic_note_id"));
                let folder = self.folder(p("smart_folder_id"));
                (
                    format!("removed {} from {}", title_of(&topic), title_of(&folder)),
                    owned(p("topic_note_id")),
                )
            }
            "tag_note" => {
                self.wrote("applied")?;
                let note = self.note(p("note_id"));
                (
                    format!("tagged {} #{}", title_of(&note), self.tag()),
                    owned(p("note_id")),
                )
            }
            "untag_note" => {
                self.wrote("removed")?;
                let note = self.note(p("note_id"));
                (
                    format!("untagged {} #{}", title_of(&note), self.tag()),
                    owned(p("note_id")),
                )
            }
            "append_to_daily_note" => (
                format!(
                    "captured {} on {}",
                    blocks(len_of(self.result, "block_ids")),
                    self.date()
                ),
                owned(r("note_id")),
            ),
            "mark_day_reviewed" => (
                format!("marked {} reviewed", self.date()),
                owned(r("note_id")),
            ),
            "create_canvas" => (
                format!("created canvas {}", title_of(or_unknown(r("title")))),
                None,
            ),
            "delete_canvas" => (
                format!(
                    "deleted canvas {}",
                    title_of(or_unknown(self.pre.canvas_title.as_deref()))
                ),
                None,
            ),
            "add_to_canvas" => {
                self.wrote("added")?;
                let note = self.canvas_note();
                let canvas = self.canvas(p("canvas_id"));
                (
                    format!("placed {} on {}", title_of(&note), title_of(&canvas)),
                    owned(p("note_id")),
                )
            }
            "move_node" => {
                self.wrote("changed")?;
                let note = self.canvas_note();
                let canvas = self.canvas(p("canvas_id"));
                (
                    format!("moved {} on {}", title_of(&note), title_of(&canvas)),
                    owned(p("note_id")),
                )
            }
            "remove_from_canvas" => {
                self.wrote("removed")?;
                let note = self.note(p("note_id"));
                let canvas = self.canvas(p("canvas_id"));
                (
                    format!("removed {} from {}", title_of(&note), title_of(&canvas)),
                    owned(p("note_id")),
                )
            }
            "update_vault_guide" => ("updated Vault Guide".to_string(), None),
            "record_feedback" => ("recorded feedback".to_string(), None),
            "resolve_feedback" => ("resolved feedback".to_string(), None),
            _ => return None,
        };
        Some((text, note_id))
    }

    /// `Some(())` unless the result's boolean `key` is an explicit `false`: a
    /// tool that cannot no-op leaves the field out, and its call wrote.
    fn wrote(&self, key: &str) -> Option<()> {
        match self.result.get(key).and_then(Value::as_bool) {
            Some(false) => None,
            _ => Some(()),
        }
    }

    /// `update_smart_folder`: renamed, moved, or both, told by the
    /// pre-snapshot. When neither differs (the snapshot raced a write by
    /// someone else) the call still wrote, so it logs as a rename.
    fn folder_update(&self) -> Option<String> {
        let new = str_of(self.result, "name");
        let old = self.pre.folder_name.as_deref();
        let renamed = old != new;
        let moved = str_of(self.result, "parent_id") != self.pre.folder_parent.as_deref();
        let new = title_of(or_unknown(new));
        let old = title_of(or_unknown(old));
        match (renamed, moved) {
            (true, true) => Some(format!("renamed and moved folder {old} → {new}")),
            (true, false) => Some(format!("renamed folder {old} → {new}")),
            (false, true) => Some(format!("moved folder {new}")),
            (false, false) => Some(format!("renamed folder {old} → {new}")),
        }
    }

    fn note(&self, id: Option<&str>) -> String {
        id.and_then(|id| self.titles.note_title(id))
            .unwrap_or_else(|| UNKNOWN.to_string())
    }

    fn folder(&self, id: Option<&str>) -> String {
        id.and_then(|id| self.titles.folder_name(id))
            .unwrap_or_else(|| UNKNOWN.to_string())
    }

    fn canvas(&self, id: Option<&str>) -> String {
        id.and_then(|id| self.titles.canvas_title(id))
            .unwrap_or_else(|| UNKNOWN.to_string())
    }

    /// The note title on a canvas row: the result's, else the lookup's.
    fn canvas_note(&self) -> String {
        match str_of(self.result, "note_title") {
            Some(title) => title.to_string(),
            None => self.note(str_of(self.params, "note_id")),
        }
    }

    /// The stored tag name: the result's, else the param without its `#`.
    fn tag(&self) -> String {
        match str_of(self.result, "tag") {
            Some(tag) => tag.to_string(),
            None => str_of(self.params, "tag")
                .map_or(UNKNOWN, |tag| tag.trim_start_matches('#'))
                .to_string(),
        }
    }

    /// The result's `date`, else the params'.
    fn date(&self) -> String {
        let date = str_of(self.result, "date").or_else(|| str_of(self.params, "date"));
        title_of(or_unknown(date))
    }
}

fn str_of<'a>(value: &'a Value, key: &str) -> Option<&'a str> {
    value.get(key).and_then(Value::as_str)
}

fn len_of(value: &Value, key: &str) -> u64 {
    let len = value.get(key).and_then(Value::as_array).map_or(0, Vec::len);
    u64::try_from(len).unwrap_or(u64::MAX)
}

fn owned(value: Option<&str>) -> Option<String> {
    value.map(str::to_string)
}

fn or_unknown(value: Option<&str>) -> &str {
    value.unwrap_or(UNKNOWN)
}

/// `1 block` or `<n> blocks`.
fn blocks(n: u64) -> String {
    match n {
        1 => "1 block".to_string(),
        _ => format!("{n} blocks"),
    }
}

/// A title or name on one line, cut to 39 chars plus `…` past 40.
fn title_of(title: &str) -> String {
    cut(&one_line(title), MAX_TITLE_CHARS)
}

/// `text` with each control char (newline, CR, tab, VT, FF, U+0085, ...) and
/// each Unicode line or paragraph separator (U+2028, U+2029) turned into a space.
fn one_line(text: &str) -> String {
    text.chars()
        .map(|c| match c {
            '\u{2028}' | '\u{2029}' => ' ',
            other if other.is_control() => ' ',
            other => other,
        })
        .collect()
}

/// `text` as is when it has at most `max` chars, else its first `max - 1`
/// chars and `…` (cut on char boundaries).
fn cut(text: &str, max: usize) -> String {
    if text.chars().count() <= max {
        return text.to_string();
    }
    let kept: String = text.chars().take(max - 1).collect();
    format!("{kept}…")
}
