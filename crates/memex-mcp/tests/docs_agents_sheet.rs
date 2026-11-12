//! WI #414 (Spec #394, D25): the Agents sheet glossary section and the docs
//! mentions.
//!
//! - GLOSSARY.md has `## Agents sheet (#394)` directly before
//!   `## Navigation (#230)`, holding the **Semantic recall** entry verbatim
//!   with its `_Avoid_` terms.
//! - `docs/claude-desktop-setup.md` and `docs/hosted-vault.md` each name the
//!   Agents sheet and its shortcut, Window menu item and sidebar link.
//! - Neither doc nor the new section uses the singular `snippet`, a GLOSSARY.md
//!   `_Avoid_` term that `docs_readme.rs` enforces against the docs.

use std::path::PathBuf;

use regex::Regex;

const SECTION_HEADING: &str = "## Agents sheet (#394)";
const NEXT_HEADING: &str = "## Navigation (#230)";
const SEMANTIC_RECALL_DEFINITION: &str = "Meaning-based matching over a vault's embedded passages, used by echoes and hybrid search. An agent's searches use it when the memex serving that agent runs with `--with-embeddings`. In the app, echoes use it on a local vault once the model is downloaded, and on a hosted vault when the vault server runs with `--with-embeddings`.";
const DOCS: [&str; 2] = ["docs/claude-desktop-setup.md", "docs/hosted-vault.md"];

fn repo_root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("..")
        .join("..")
}

fn read_repo_file(rel: &str) -> String {
    let path = repo_root().join(rel);
    std::fs::read_to_string(&path)
        .unwrap_or_else(|e| panic!("{rel} must exist and be readable ({}): {e}", path.display()))
}

/// The `## ` headings of a markdown file, outside fenced code blocks.
fn h2_headings(markdown: &str) -> Vec<String> {
    let mut in_fence = false;
    let mut out = Vec::new();
    for line in markdown.lines() {
        if line.starts_with("```") {
            in_fence = !in_fence;
        } else if !in_fence && line.starts_with("## ") {
            out.push(line.trim_end().to_string());
        }
    }
    out
}

/// The body of the Agents sheet section: the lines after its heading up to the
/// next `## ` heading.
fn agents_sheet_section() -> String {
    let glossary = read_repo_file("GLOSSARY.md");
    let mut lines = glossary.lines();
    lines
        .by_ref()
        .find(|l| l.trim_end() == SECTION_HEADING)
        .unwrap_or_else(|| panic!("GLOSSARY.md has the heading `{SECTION_HEADING}`"));
    lines
        .take_while(|l| !l.starts_with("## "))
        .collect::<Vec<_>>()
        .join("\n")
}

fn singular_snippet() -> Regex {
    Regex::new(r"(?i)\bsnippet\b").unwrap()
}

#[test]
fn glossary_has_exactly_one_agents_sheet_section() {
    let headings = h2_headings(&read_repo_file("GLOSSARY.md"));
    let count = headings.iter().filter(|h| *h == SECTION_HEADING).count();
    assert_eq!(count, 1, "GLOSSARY.md has one `{SECTION_HEADING}` heading");
}

#[test]
fn agents_sheet_section_sits_directly_before_navigation() {
    let headings = h2_headings(&read_repo_file("GLOSSARY.md"));
    let at = headings
        .iter()
        .position(|h| h == SECTION_HEADING)
        .unwrap_or_else(|| panic!("GLOSSARY.md has the heading `{SECTION_HEADING}`"));
    assert_eq!(
        headings.get(at + 1).map(String::as_str),
        Some(NEXT_HEADING),
        "`{NEXT_HEADING}` is the next `## ` heading after `{SECTION_HEADING}`"
    );
}

#[test]
fn semantic_recall_entry_is_verbatim_with_avoid_terms() {
    let section = agents_sheet_section();
    let expected = format!(
        "**Semantic recall**:\n{SEMANTIC_RECALL_DEFINITION}\n_Avoid_: AI search, smart search"
    );
    assert!(
        section.contains(&expected),
        "the section holds the Semantic recall entry verbatim:\n{expected}\n--- section was ---\n{section}"
    );
    assert_eq!(
        section.matches("**Semantic recall**").count(),
        1,
        "exactly one Semantic recall entry"
    );
}

#[test]
fn semantic_recall_avoid_line_lists_exactly_the_two_terms() {
    let section = agents_sheet_section();
    let avoid: Vec<&str> = section
        .lines()
        .filter(|l| l.starts_with("_Avoid_:"))
        .collect();
    assert_eq!(
        avoid,
        vec!["_Avoid_: AI search, smart search"],
        "one `_Avoid_` line with AI search and smart search"
    );
}

#[test]
fn agents_sheet_section_has_no_singular_snippet() {
    let section = agents_sheet_section();
    assert!(
        !section.trim().is_empty(),
        "the section exists and is not empty"
    );
    assert!(
        !singular_snippet().is_match(&section),
        "the Agents sheet section never uses the singular `snippet`"
    );
}

#[test]
fn setup_docs_name_the_agents_sheet_and_its_shortcut() {
    for doc in DOCS {
        let text = read_repo_file(doc);
        assert!(
            text.contains("Agents sheet"),
            "{doc} names the Agents sheet"
        );
        assert!(text.contains("⇧⌘A"), "{doc} names the shortcut ⇧⌘A");
    }
}

#[test]
fn setup_docs_name_the_window_menu_item_and_sidebar_link() {
    for doc in DOCS {
        let text = read_repo_file(doc);
        assert!(
            text.contains("Window ▸ Agents…"),
            "{doc} names the Window ▸ Agents… menu item"
        );
        assert!(
            text.contains("`OPEN ↗`"),
            "{doc} names the sidebar's `OPEN ↗` link"
        );
    }
}

#[test]
fn setup_docs_say_the_sheet_fills_in_the_setup_for_this_vault() {
    for doc in DOCS {
        let text = read_repo_file(doc);
        let paragraph = text
            .split("\n\n")
            .find(|p| p.contains("Agents sheet"))
            .unwrap_or_else(|| panic!("{doc} has a paragraph naming the Agents sheet"));
        assert!(
            paragraph.contains("snippets"),
            "{doc}: the Agents sheet paragraph says it hands out the setup snippets:\n{paragraph}"
        );
        assert!(
            paragraph.contains("this vault"),
            "{doc}: the Agents sheet paragraph says they are filled in for this vault:\n{paragraph}"
        );
    }
}

#[test]
fn setup_docs_have_no_singular_snippet() {
    for doc in DOCS {
        let text = read_repo_file(doc);
        assert!(
            !singular_snippet().is_match(&text),
            "{doc} never uses the singular `snippet`"
        );
    }
}
