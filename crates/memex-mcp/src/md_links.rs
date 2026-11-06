//! Markdown surgery for `add_link`. Inserts `[[Title]]` (or `[[Title|alias]]`)
//! into a source note's content_md per the kind→destination rule:
//!
//! * `references` (default) → append into a `## Auto-added links` section at
//!   the bottom (creating the section if absent).
//! * Any other kind (built-in or user-defined) → insert into YAML frontmatter
//!   under the kind key in list form.
//!
//! Pure functions; no I/O. Used by both the CLI `add-link` subcommand and the
//! MCP `add_link` tool.

const AUTO_ADDED_HEADING: &str = "## Auto-added links";

/// Insert a wikilink into the source note's content per the destination rule.
///
/// Only the person section is edited: a Note footer (from the first marker
/// line outside fenced code) is kept byte for byte below it (Spec #234 R15).
pub fn insert_link_into_markdown(
    content: &str,
    target_title: &str,
    kind: &str,
    label: Option<&str>,
) -> String {
    let (person, footer) =
        content.split_at(memex_core::daily::note_marker_start(content).unwrap_or(content.len()));
    let token = render_wikilink(target_title, label);
    let mut out = if kind == "references" {
        insert_into_auto_added(person, &token)
    } else {
        insert_into_frontmatter(person, &token, kind)
    };
    out.push_str(footer);
    out
}

/// Render the wikilink token to insert: `[[Title]]`, or `[[Title|alias]]` when
/// a non-empty label is given. Every kind uses the same token; no `~kind`
/// segment is written because frontmatter-bound kinds carry the kind in the
/// YAML key.
fn render_wikilink(title: &str, label: Option<&str>) -> String {
    match label {
        Some(l) if !l.is_empty() => format!("[[{title}|{l}]]"),
        _ => format!("[[{title}]]"),
    }
}

fn insert_into_auto_added(content: &str, token: &str) -> String {
    let lines: Vec<&str> = content.lines().collect();

    // Find the existing `## Auto-added links` heading.
    if let Some(start) = lines.iter().position(|l| l.trim() == AUTO_ADDED_HEADING) {
        // Walk to end of section: next ATX heading at the same depth or higher,
        // or EOF.
        let mut end = lines.len();
        for (i, line) in lines.iter().enumerate().skip(start + 1) {
            if line.starts_with("# ") || line.starts_with("## ") || line.starts_with("###") {
                end = i;
                break;
            }
        }
        let mut out = lines[..end].join("\n");
        if !out.ends_with('\n') {
            out.push('\n');
        }
        // Ensure a blank line between previous content and the new entry if
        // the section is otherwise empty (heading immediately followed by EOF
        // or another heading).
        if start + 1 == end {
            out.push('\n');
        }
        out.push_str(token);
        out.push('\n');
        if end < lines.len() {
            out.push_str(&lines[end..].join("\n"));
            if !out.ends_with('\n') {
                out.push('\n');
            }
        }
        return out;
    }

    // Section absent — append to the bottom.
    let mut out = content.to_string();
    while out.ends_with('\n') {
        out.pop();
    }
    out.push_str("\n\n");
    out.push_str(AUTO_ADDED_HEADING);
    out.push_str("\n\n");
    out.push_str(token);
    out.push('\n');
    out
}

/// Insert the already-rendered `token` under the `kind` key in the note's YAML
/// frontmatter, creating the frontmatter, the key or the list as needed.
fn insert_into_frontmatter(content: &str, token: &str, kind: &str) -> String {
    // Detect a `---\n...\n---\n` block at the very start.
    if !content.starts_with("---\n") && !content.starts_with("---\r\n") {
        // No frontmatter — prepend a fresh one.
        return format!("---\n{kind}:\n  - {token}\n---\n{content}");
    }
    // Find the closing fence. Look for "\n---\n" or "\n---\r\n" or "\n---" at EOF.
    let after_open = content.find('\n').map(|n| n + 1).unwrap_or(content.len());
    let rest = &content[after_open..];
    let close_idx = match rest.find("\n---\n").map(|i| i + after_open) {
        Some(i) => Some(i),
        None => rest.find("\n---\r\n").map(|i| i + after_open),
    };
    let Some(close_at) = close_idx else {
        // Malformed — prepend a fresh frontmatter block.
        return format!("---\n{kind}:\n  - {token}\n---\n{content}");
    };
    let fm_text = &content[after_open..close_at];
    // Skip past the closing fence line.
    let body_start = match content[close_at + 1..].find('\n') {
        Some(n) => close_at + 1 + n + 1,
        None => content.len(),
    };
    let body = &content[body_start..];

    // Walk frontmatter line-by-line, looking for a `<kind>:` key.
    let mut new_fm = String::new();
    let mut inserted = false;
    let lines: Vec<&str> = fm_text.lines().collect();
    let mut i = 0;
    while i < lines.len() {
        let line = lines[i];
        if !inserted && line_is_key(line, kind) {
            new_fm.push_str(line);
            new_fm.push('\n');
            // Inline scalar value? `<kind>: <something>` (after `:` is
            // non-empty after trim).
            let after_colon = line
                .split_once(':')
                .map(|(_, r)| r.trim())
                .unwrap_or("");
            if after_colon.is_empty() {
                // Block list form: walk forward over `  - ...` items, then
                // append a new one at the end of the list.
                let mut j = i + 1;
                while j < lines.len() && is_list_item(lines[j]) {
                    new_fm.push_str(lines[j]);
                    new_fm.push('\n');
                    j += 1;
                }
                new_fm.push_str("  - ");
                new_fm.push_str(token);
                new_fm.push('\n');
                inserted = true;
                i = j;
                continue;
            } else {
                // Inline scalar — convert to a block list.
                // Pop the line we just pushed; rewrite without the inline value.
                new_fm.truncate(new_fm.len() - line.len() - 1);
                new_fm.push_str(kind);
                new_fm.push_str(":\n");
                new_fm.push_str("  - ");
                new_fm.push_str(after_colon);
                new_fm.push('\n');
                new_fm.push_str("  - ");
                new_fm.push_str(token);
                new_fm.push('\n');
                inserted = true;
                i += 1;
                continue;
            }
        } else {
            new_fm.push_str(line);
            new_fm.push('\n');
        }
        i += 1;
    }
    if !inserted {
        // Append a fresh key.
        new_fm.push_str(kind);
        new_fm.push_str(":\n  - ");
        new_fm.push_str(token);
        new_fm.push('\n');
    }

    let mut out = String::new();
    out.push_str("---\n");
    out.push_str(&new_fm);
    out.push_str("---\n");
    out.push_str(body);
    out
}

fn line_is_key(line: &str, key: &str) -> bool {
    // Top-level YAML key (no leading whitespace), `<key>:` followed by EOL or value.
    if line.starts_with(' ') || line.starts_with('\t') {
        return false;
    }
    let prefix = format!("{key}:");
    line == prefix || line.starts_with(&prefix)
}

fn is_list_item(line: &str) -> bool {
    let trimmed_start = line.trim_start();
    trimmed_start.starts_with("- ") || trimmed_start == "-"
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn appends_auto_added_section_when_absent() {
        let original = "Hello there.";
        let out = insert_link_into_markdown(original, "Foo", "references", None);
        assert!(out.contains("## Auto-added links"));
        assert!(out.contains("[[Foo]]"));
        // Original content preserved.
        assert!(out.starts_with("Hello there."));
    }

    #[test]
    fn appends_into_existing_auto_added_section() {
        let original = "Hello.\n\n## Auto-added links\n\n[[Bar]]\n";
        let out = insert_link_into_markdown(original, "Foo", "references", None);
        assert_eq!(out.matches("## Auto-added links").count(), 1);
        assert!(out.contains("[[Bar]]"));
        assert!(out.contains("[[Foo]]"));
    }

    #[test]
    fn appends_to_section_when_followed_by_other_heading() {
        let original = "## Auto-added links\n\n[[Bar]]\n\n## Other\n\nstuff";
        let out = insert_link_into_markdown(original, "Foo", "references", None);
        // Foo must appear before "## Other".
        let foo_at = out.find("[[Foo]]").unwrap();
        let other_at = out.find("## Other").unwrap();
        assert!(foo_at < other_at);
        // "## Other" + "stuff" preserved.
        assert!(out.contains("\nstuff"));
    }

    #[test]
    fn references_with_alias_renders_pipe_form() {
        let out = insert_link_into_markdown("body", "Foo", "references", Some("Display"));
        assert!(out.contains("[[Foo|Display]]"));
    }

    #[test]
    fn typed_kind_creates_frontmatter_when_absent() {
        let original = "# Title\nbody";
        let out = insert_link_into_markdown(original, "Foo", "extends", None);
        assert!(out.starts_with("---\n"));
        assert!(out.contains("extends:\n  - [[Foo]]\n"));
        assert!(out.contains("---\n# Title\nbody"));
    }

    #[test]
    fn typed_kind_appends_to_existing_block_list() {
        let original = "---\nextends:\n  - [[A]]\n  - [[B]]\n---\nbody";
        let out = insert_link_into_markdown(original, "Foo", "extends", None);
        // Three list items in order.
        let extends_block = out.split("---").nth(1).unwrap();
        assert!(extends_block.contains("- [[A]]"));
        assert!(extends_block.contains("- [[B]]"));
        assert!(extends_block.contains("- [[Foo]]"));
        // Body preserved.
        assert!(out.contains("---\nbody"));
    }

    #[test]
    fn typed_kind_converts_inline_scalar_to_list() {
        let original = "---\nextends: [[A]]\n---\nbody";
        let out = insert_link_into_markdown(original, "Foo", "extends", None);
        // Both A and Foo become list items under extends.
        assert!(out.contains("extends:\n"));
        assert!(out.contains("  - [[A]]"));
        assert!(out.contains("  - [[Foo]]"));
    }

    #[test]
    fn typed_kind_adds_new_key_when_other_keys_present() {
        let original = "---\nextends:\n  - [[A]]\n---\nbody";
        let out = insert_link_into_markdown(original, "B", "contradicts", None);
        assert!(out.contains("extends:\n  - [[A]]"));
        assert!(out.contains("contradicts:\n  - [[B]]"));
    }

    #[test]
    fn user_defined_kind_writes_to_frontmatter() {
        let original = "body";
        let out = insert_link_into_markdown(original, "Bush", "inspired-by", None);
        assert!(out.contains("inspired-by:\n  - [[Bush]]"));
    }

    // WI #140: the label is kept for every kind, in every frontmatter shape.

    #[test]
    fn label_kept_for_every_kind() {
        let cases = [
            (
                "references",
                "body\n\n## Auto-added links\n\n[[Foo|Lbl-references]]\n",
            ),
            (
                "extends",
                "---\nextends:\n  - [[Foo|Lbl-extends]]\n---\nbody",
            ),
            (
                "contradicts",
                "---\ncontradicts:\n  - [[Foo|Lbl-contradicts]]\n---\nbody",
            ),
            (
                "example-of",
                "---\nexample-of:\n  - [[Foo|Lbl-example-of]]\n---\nbody",
            ),
            (
                "inspired-by",
                "---\ninspired-by:\n  - [[Foo|Lbl-inspired-by]]\n---\nbody",
            ),
        ];
        for (kind, expected) in cases {
            let label = format!("Lbl-{kind}");
            let out = insert_link_into_markdown("body", "Foo", kind, Some(&label));
            assert_eq!(out, expected, "kind {kind}");
        }
    }

    #[test]
    fn frontmatter_label_kept_when_frontmatter_absent() {
        let original = "# Title\nbody";
        let out = insert_link_into_markdown(original, "Foo", "extends", Some("Lbl"));
        assert_eq!(out, "---\nextends:\n  - [[Foo|Lbl]]\n---\n# Title\nbody");
    }

    #[test]
    fn frontmatter_label_kept_when_appending_to_block_list() {
        let original = "---\ntitle: T\nextends:\n  - [[A]]\n  - [[B|b label]]\ntags: x\n---\nbody";
        let out = insert_link_into_markdown(original, "Foo", "extends", Some("Lbl"));
        assert_eq!(
            out,
            "---\ntitle: T\nextends:\n  - [[A]]\n  - [[B|b label]]\n  - [[Foo|Lbl]]\ntags: x\n---\nbody"
        );
    }

    #[test]
    fn frontmatter_label_kept_when_converting_inline_scalar() {
        let original = "---\ntitle: T\nextends: [[A|a label]]\n---\nbody";
        let out = insert_link_into_markdown(original, "Foo", "extends", Some("Lbl"));
        assert_eq!(
            out,
            "---\ntitle: T\nextends:\n  - [[A|a label]]\n  - [[Foo|Lbl]]\n---\nbody"
        );
    }

    #[test]
    fn frontmatter_label_kept_when_adding_new_key() {
        let original = "---\nextends:\n  - [[A]]\n---\nbody";
        let out = insert_link_into_markdown(original, "B", "contradicts", Some("Lbl"));
        assert_eq!(
            out,
            "---\nextends:\n  - [[A]]\ncontradicts:\n  - [[B|Lbl]]\n---\nbody"
        );
    }

    #[test]
    fn frontmatter_label_kept_when_frontmatter_unclosed() {
        let original = "---\nnot closed\nbody";
        let out = insert_link_into_markdown(original, "Foo", "extends", Some("Lbl"));
        assert_eq!(
            out,
            "---\nextends:\n  - [[Foo|Lbl]]\n---\n---\nnot closed\nbody"
        );
    }

    #[test]
    fn no_label_or_empty_label_writes_no_pipe() {
        let cases = [
            (
                "body",
                "references",
                "body\n\n## Auto-added links\n\n[[Foo]]\n",
            ),
            (
                "# T\nbody",
                "extends",
                "---\nextends:\n  - [[Foo]]\n---\n# T\nbody",
            ),
            (
                "---\nextends:\n  - [[A]]\n---\nbody",
                "extends",
                "---\nextends:\n  - [[A]]\n  - [[Foo]]\n---\nbody",
            ),
            (
                "---\nextends: [[A]]\n---\nbody",
                "extends",
                "---\nextends:\n  - [[A]]\n  - [[Foo]]\n---\nbody",
            ),
            (
                "---\nextends:\n  - [[A]]\n---\nbody",
                "inspired-by",
                "---\nextends:\n  - [[A]]\ninspired-by:\n  - [[Foo]]\n---\nbody",
            ),
        ];
        for (original, kind, expected) in cases {
            for label in [None, Some("")] {
                let out = insert_link_into_markdown(original, "Foo", kind, label);
                assert_eq!(out, expected, "kind {kind}, label {label:?}");
                assert!(!out.contains('|'), "no pipe: {out:?}");
            }
        }
    }

    #[test]
    fn frontmatter_label_special_characters_written_verbatim() {
        let label = "a: b # c 'd' \"e\"";
        let out = insert_link_into_markdown("body", "Foo", "extends", Some(label));
        assert_eq!(
            out,
            "---\nextends:\n  - [[Foo|a: b # c 'd' \"e\"]]\n---\nbody"
        );
    }
}
