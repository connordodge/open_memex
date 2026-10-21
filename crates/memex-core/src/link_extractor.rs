//! Pure markdown → links parser. The indexer calls `extract` on every save;
//! the result is what populates the `links` table.
//!
//! Wikilink syntax: `[[Title]]`, `[[Title~kind]]`, `[[Title|alias]]`,
//! `[[Title~kind|alias]]`. The kind separator is tilde (caret marks a block
//! id in transclusion); the alias separator is pipe.
//!
//! Block transclusion: `![[YYYY-MM-DD#^from]]` and `![[YYYY-MM-DD#^from..^to]]`
//! (CONTRACTS C4). Each token yields one `from-day` link at the byte offset of
//! its `!` and never a plain wikilink for the `[[…]]` inside it.
//!
//! Built-in kinds recognized via curated section headings + frontmatter keys:
//! `references`, `extends`, `contradicts`, `example-of`. The built-in
//! `from-day` and `about` kinds are server-written: no heading or frontmatter
//! key creates them. User-defined kinds (any normalized kebab-case string) are
//! first-class for storage and `neighbors()` queries but get no curated
//! shortcut.

use std::sync::LazyLock;

use regex::{Regex, RegexBuilder};

use crate::links::{normalize, LinkKind, LinkSource, PendingLink};

/// What `extract` produces. The indexer feeds this into `links` rows + the
/// per-note flag columns.
#[derive(Debug, Clone, Default)]
pub struct ExtractedLinks {
    pub body: Vec<PendingLink>,
    pub frontmatter: Vec<PendingLink>,
    pub has_open_questions: bool,
    pub frontmatter_parse_error: bool,
}

impl ExtractedLinks {
    pub fn all(&self) -> impl Iterator<Item = &PendingLink> {
        self.body.iter().chain(self.frontmatter.iter())
    }
}

/// One block-transclusion token (`![[YYYY-MM-DD#^from]]` or
/// `![[YYYY-MM-DD#^from..^to]]`, CONTRACTS C4). `start` and `end` are UTF-8
/// byte offsets into the parsed text: `start` is the `!`, `end` is one past
/// the closing `]]` (D25; search builds on these ranges).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TransclusionToken {
    pub date: String,
    pub from: String,
    pub to: Option<String>,
    pub start: usize,
    pub end: usize,
}

/// The CONTRACTS C4 transclusion regex, verbatim (D13: identical in Rust and
/// Dart).
const TRANSCLUSION_PATTERN: &str =
    r"!\[\[(\d{4}-\d{2}-\d{2})#\^([0-9a-z]{1,26})(?:\.\.\^([0-9a-z]{1,26}))?\]\]";

// Compiled without Unicode classes so `\d` is ASCII-only, as in Dart.
static TRANSCLUSION_RE: LazyLock<Regex> = LazyLock::new(|| {
    RegexBuilder::new(TRANSCLUSION_PATTERN)
        .unicode(false)
        .build()
        .expect("compile transclusion regex")
});

/// Every transclusion token in `text`, in order (D13, CONTRACTS C4).
pub fn parse_transclusions(text: &str) -> Vec<TransclusionToken> {
    TRANSCLUSION_RE
        .captures_iter(text)
        .map(|cap| {
            let whole = cap.get(0).expect("group 0 always matches");
            TransclusionToken {
                date: cap[1].to_string(),
                from: cap[2].to_string(),
                to: cap.get(3).map(|m| m.as_str().to_string()),
                start: whole.start(),
                end: whole.end(),
            }
        })
        .collect()
}

// `[[<title>(~<kind>)?(|<alias>)?]]` — title cannot contain `~`, `|`, `]`, or
// newline; kind cannot contain `|`, `]`, or newline; alias cannot contain `]`
// or newline.
static WIKILINK_RE: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(
        r"\[\[(?P<title>[^\[\]\n~|]+?)(?:~(?P<kind>[^\[\]\n|]+?))?(?:\|(?P<alias>[^\[\]\n]+?))?\]\]",
    )
    .expect("compile wikilink regex")
});

// ATX `##` headings only (depth 2). `(?m)^` matches start of line in multiline
// mode; we strip trailing whitespace and a possible trailing `##`.
static H2_RE: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"(?m)^[ \t]*##[ \t]+(?P<text>.+?)[ \t]*#*[ \t]*$")
        .expect("compile h2 regex")
});

pub fn extract(content_md: &str) -> ExtractedLinks {
    let (frontmatter_region, body_offset) = split_frontmatter(content_md);

    let mut out = ExtractedLinks::default();

    if let Some((fm_text, fm_offset)) = frontmatter_region {
        match parse_frontmatter(fm_text, fm_offset) {
            Ok(links) => out.frontmatter = links,
            Err(()) => {
                out.frontmatter_parse_error = true;
            }
        }
    }

    let body = &content_md[body_offset..];
    out.body = extract_body_links(body, body_offset);
    out.has_open_questions = body_has_open_questions(body);

    out
}

/// Returns `(Some((frontmatter_text, frontmatter_byte_offset)), body_byte_offset)`
/// if a frontmatter block is present at the start of the input. `body_byte_offset`
/// is the index in `content_md` where the body begins (i.e., one past the
/// closing `---` line).
fn split_frontmatter(content_md: &str) -> (Option<(&str, usize)>, usize) {
    // Frontmatter must start at byte 0 with a line that is exactly `---`.
    let bytes = content_md.as_bytes();
    if bytes.len() < 4 || &bytes[..3] != b"---" {
        return (None, 0);
    }
    // Line ending after the opening `---`.
    let after_open = match find_line_end(content_md, 3) {
        Some(i) => i,
        None => return (None, 0),
    };
    // Look for the next line that is exactly `---`.
    let mut cursor = after_open;
    while cursor < content_md.len() {
        let line_start = cursor;
        let line_end = find_line_end(content_md, line_start).unwrap_or(content_md.len());
        let line = &content_md[line_start..line_end].trim_end_matches(['\r', '\n']);
        if line.trim() == "---" {
            // The body starts after this line's trailing newline.
            let body_start = find_line_end(content_md, line_start).unwrap_or(content_md.len());
            let fm_text = &content_md[after_open..line_start];
            return (Some((fm_text, after_open)), body_start);
        }
        cursor = match find_line_end(content_md, line_start) {
            Some(i) if i > line_start => i,
            _ => break,
        };
    }
    // No closing `---` found — treat as no frontmatter.
    (None, 0)
}

/// Returns the byte index just after the next `\n`, or None if no newline.
fn find_line_end(s: &str, start: usize) -> Option<usize> {
    s[start..].find('\n').map(|n| start + n + 1)
}

fn parse_frontmatter(fm_text: &str, fm_offset: usize) -> std::result::Result<Vec<PendingLink>, ()> {
    use serde_yaml::Value;
    // Pre-process: quote bare `[[Title]]` tokens so YAML parses them as strings
    // instead of nested flow sequences. Users would otherwise have to write
    // `extends: "[[Foo]]"` everywhere — both forms now work.
    let preprocessed = quote_bare_wikilinks(fm_text);
    let val: Value = serde_yaml::from_str(&preprocessed).map_err(|_| ())?;
    let map = match val {
        Value::Mapping(m) => m,
        Value::Null => return Ok(Vec::new()),
        _ => return Err(()),
    };
    let mut out: Vec<PendingLink> = Vec::new();
    for (key, value) in map {
        let Some(key_str) = key.as_str() else {
            continue;
        };
        // Built-in keys with synonyms.
        let kind_str = match key_str {
            "references" => "references".to_string(),
            "extends" => "extends".to_string(),
            "contradicts" => "contradicts".to_string(),
            "example-of" | "example_of" => "example-of".to_string(),
            other => normalize(other),
        };
        // `from-day` and `about` are server-written kinds: no frontmatter key
        // creates them.
        if kind_str == LinkKind::FROM_DAY || kind_str == LinkKind::ABOUT {
            continue;
        }
        let Ok(kind) = LinkKind::new(&kind_str) else {
            continue;
        };
        collect_wikilinks_from_value(&value, &kind, fm_text, fm_offset, &mut out);
    }
    Ok(out)
}

/// Recursively walk a YAML value collecting `[[Title]]` strings.
/// Bare strings (no `[[...]]` form) are intentionally ignored.
fn collect_wikilinks_from_value(
    value: &serde_yaml::Value,
    kind: &LinkKind,
    fm_text: &str,
    fm_offset: usize,
    out: &mut Vec<PendingLink>,
) {
    match value {
        serde_yaml::Value::String(s) => add_fm_links(out, s, kind, fm_text, fm_offset),
        serde_yaml::Value::Sequence(seq) => {
            for v in seq {
                collect_wikilinks_from_value(v, kind, fm_text, fm_offset, out);
            }
        }
        _ => {}
    }
}

/// Wrap any unquoted `[[Title]]` (including with `~kind` and `|alias`) tokens
/// in double quotes so YAML parses them as strings rather than flow sequences.
/// Skips occurrences that already sit inside a double-quoted string. Skips
/// occurrences that begin a quoted-style YAML key (we operate only on values).
fn quote_bare_wikilinks(s: &str) -> String {
    let mut out = String::with_capacity(s.len() + 16);
    let mut in_double = false;
    let mut in_single = false;
    let bytes = s.as_bytes();
    let mut i = 0;
    while i < bytes.len() {
        let c = bytes[i];
        if !in_single && c == b'"' {
            in_double = !in_double;
            out.push(c as char);
            i += 1;
            continue;
        }
        if !in_double && c == b'\'' {
            in_single = !in_single;
            out.push(c as char);
            i += 1;
            continue;
        }
        if !in_double && !in_single && c == b'[' && i + 1 < bytes.len() && bytes[i + 1] == b'[' {
            // Find the matching `]]` within the same line.
            let mut j = i + 2;
            let mut found = None;
            while j + 1 < bytes.len() {
                if bytes[j] == b'\n' {
                    break;
                }
                if bytes[j] == b']' && bytes[j + 1] == b']' {
                    found = Some(j + 2);
                    break;
                }
                j += 1;
            }
            if let Some(end) = found {
                let token = &s[i..end];
                // Quote: replace any internal `"` with `\"` (rare).
                out.push('"');
                for ch in token.chars() {
                    if ch == '"' {
                        out.push('\\');
                    }
                    out.push(ch);
                }
                out.push('"');
                i = end;
                continue;
            }
        }
        out.push(c as char);
        i += 1;
    }
    out
}

/// Scan a frontmatter scalar for `[[Title]]` tokens (only `[[Title]]` form;
/// bare strings are intentionally ignored to avoid silent-rename issues).
fn add_fm_links(
    out: &mut Vec<PendingLink>,
    s: &str,
    kind: &LinkKind,
    fm_text: &str,
    fm_offset: usize,
) {
    for cap in WIKILINK_RE.captures_iter(s) {
        let title = cap.name("title").unwrap().as_str().trim().to_string();
        if title.is_empty() {
            continue;
        }
        let alias = cap
            .name("alias")
            .map(|m| m.as_str().trim().to_string())
            .filter(|s| !s.is_empty());
        // Compute position: byte offset of the `[[` within content_md. The
        // captured match index is into `s`; we don't have the offset of `s`
        // within fm_text, so we do a substring search for the capture string.
        let capture_str = cap.get(0).unwrap().as_str();
        let pos_in_fm = fm_text.find(capture_str).unwrap_or(0);
        out.push(PendingLink {
            link_text: title,
            link_kind: kind.clone(),
            label: alias,
            position: (fm_offset + pos_in_fm) as i64,
            source: LinkSource::Frontmatter,
        });
    }
}

fn extract_body_links(body: &str, body_offset: usize) -> Vec<PendingLink> {
    // Build a list of (heading_byte_offset, mapped_kind?) for h2 headings.
    let headings: Vec<(usize, Option<&'static str>)> = H2_RE
        .captures_iter(body)
        .map(|cap| {
            let m = cap.get(0).unwrap();
            let text = cap.name("text").unwrap().as_str();
            (m.start(), section_kind_for_heading(text))
        })
        .collect();

    // Each transclusion token is one `from-day` link at its `!`. Mask the
    // token spans with same-length filler before the wikilink scan so the
    // `[[…]]` inside a token is never a plain link and every other wikilink
    // keeps its exact byte offset. Newline is excluded from every wikilink
    // group, so no match can span a masked token.
    let tokens = parse_transclusions(body);
    let mut masked = body.as_bytes().to_vec();
    let mut out = Vec::with_capacity(tokens.len());
    for t in &tokens {
        masked[t.start..t.end].fill(b'\n');
        out.push(PendingLink {
            link_text: t.date.clone(),
            link_kind: LinkKind::new(LinkKind::FROM_DAY).expect("built-in kind valid"),
            label: None,
            position: (body_offset + t.start) as i64,
            source: LinkSource::InlineBody,
        });
    }
    // Tokens are ASCII, so replacing them byte for byte keeps valid UTF-8.
    let masked = String::from_utf8(masked).expect("masking ASCII spans keeps UTF-8");

    for cap in WIKILINK_RE.captures_iter(&masked) {
        let m = cap.get(0).unwrap();
        let title = cap.name("title").unwrap().as_str().trim().to_string();
        if title.is_empty() {
            continue;
        }

        // Determine kind: explicit > section > default (references).
        let explicit_kind: Option<LinkKind> =
            cap.name("kind").and_then(|k| match LinkKind::new(k.as_str()) {
                Ok(lk) => Some(lk),
                Err(_) => {
                    tracing::warn!(invalid_kind = %k.as_str(), title = %title, "wikilink kind invalid; falling back to references");
                    None
                }
            });

        let (kind, source) = match explicit_kind {
            Some(k) => (k, LinkSource::InlineBody),
            None => {
                // Find closest preceding heading.
                let preceding = headings
                    .iter()
                    .rev()
                    .find(|(off, _)| *off <= m.start());
                match preceding.and_then(|(_, k)| *k) {
                    Some(kind_str) => (
                        LinkKind::new(kind_str).expect("built-in kind valid"),
                        LinkSource::InlineSection,
                    ),
                    None => (LinkKind::references(), LinkSource::InlineBody),
                }
            }
        };

        let alias = cap
            .name("alias")
            .map(|a| a.as_str().trim().to_string())
            .filter(|s| !s.is_empty());

        out.push(PendingLink {
            link_text: title,
            link_kind: kind,
            label: alias,
            position: (body_offset + m.start()) as i64,
            source,
        });
    }
    out.sort_by_key(|l| l.position);
    out
}

fn section_kind_for_heading(text: &str) -> Option<&'static str> {
    let t = text.trim().to_lowercase();
    match t.as_str() {
        "contradicts" => Some(LinkKind::CONTRADICTS),
        "extends" | "builds on" | "builds-on" => Some(LinkKind::EXTENDS),
        "example of" | "examples" => Some(LinkKind::EXAMPLE_OF),
        "see also" | "references" => Some(LinkKind::REFERENCES),
        // "Open questions" doesn't induce a kind; it's tracked separately.
        _ => None,
    }
}

fn body_has_open_questions(body: &str) -> bool {
    H2_RE
        .captures_iter(body)
        .any(|cap| cap.name("text").unwrap().as_str().trim().eq_ignore_ascii_case("open questions"))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn kinds(links: &[PendingLink]) -> Vec<&str> {
        links.iter().map(|l| l.link_kind.as_str()).collect()
    }

    #[test]
    fn empty_input_is_empty_extraction() {
        let r = extract("");
        assert!(r.body.is_empty());
        assert!(r.frontmatter.is_empty());
        assert!(!r.has_open_questions);
        assert!(!r.frontmatter_parse_error);
    }

    #[test]
    fn body_simple_wikilink_default_kind() {
        let r = extract("Hello [[Foo]] world.");
        assert_eq!(r.body.len(), 1);
        assert_eq!(r.body[0].link_text, "Foo");
        assert_eq!(r.body[0].link_kind.as_str(), "references");
        assert_eq!(r.body[0].source, LinkSource::InlineBody);
        // position = byte offset of `[[`.
        assert_eq!(r.body[0].position, "Hello ".len() as i64);
    }

    #[test]
    fn body_typed_wikilink_extends() {
        let r = extract("This [[Foo~extends]] thing.");
        assert_eq!(kinds(&r.body), vec!["extends"]);
        assert_eq!(r.body[0].source, LinkSource::InlineBody);
    }

    #[test]
    fn body_user_defined_kind() {
        let r = extract("Was [[Foo~inspired-by]] this.");
        assert_eq!(kinds(&r.body), vec!["inspired-by"]);
        assert!(!r.body[0].link_kind.is_built_in());
    }

    #[test]
    fn body_alias_only() {
        let r = extract("Read [[Foo|My Foo]] later.");
        assert_eq!(r.body[0].link_text, "Foo");
        assert_eq!(r.body[0].link_kind.as_str(), "references");
        assert_eq!(r.body[0].label.as_deref(), Some("My Foo"));
    }

    #[test]
    fn body_kind_and_alias() {
        let r = extract("[[Foo~extends|alias text]]");
        assert_eq!(r.body[0].link_kind.as_str(), "extends");
        assert_eq!(r.body[0].label.as_deref(), Some("alias text"));
    }

    #[test]
    fn body_invalid_kind_falls_back_to_references() {
        let r = extract("[[Foo~Made_Up]]");
        assert_eq!(kinds(&r.body), vec!["references"]);
    }

    #[test]
    fn body_section_grouping_under_h2() {
        let r = extract("# Note\n\n## Contradicts\n\n[[Foo]]\n[[Bar]]\n\n## Other\n\n[[Baz]]");
        let kinds_list = kinds(&r.body);
        assert_eq!(kinds_list, vec!["contradicts", "contradicts", "references"]);
        assert_eq!(r.body[0].source, LinkSource::InlineSection);
        assert_eq!(r.body[2].source, LinkSource::InlineBody);
    }

    #[test]
    fn body_explicit_kind_overrides_section() {
        let r = extract("## Contradicts\n\n[[Foo~references]]");
        assert_eq!(r.body[0].link_kind.as_str(), "references");
        assert_eq!(r.body[0].source, LinkSource::InlineBody);
    }

    #[test]
    fn frontmatter_built_in_keys() {
        let md = "---\nextends: [[Foo]]\ncontradicts:\n  - [[Bar]]\n---\nbody";
        let r = extract(md);
        assert_eq!(r.frontmatter.len(), 2);
        let by_kind: Vec<_> = r.frontmatter.iter().map(|l| (l.link_kind.as_str(), l.link_text.as_str())).collect();
        assert!(by_kind.contains(&("extends", "Foo")));
        assert!(by_kind.contains(&("contradicts", "Bar")));
        for l in &r.frontmatter {
            assert_eq!(l.source, LinkSource::Frontmatter);
        }
    }

    #[test]
    fn frontmatter_user_defined_key() {
        let md = "---\ninspired-by:\n  - [[Foo]]\n---\nbody";
        let r = extract(md);
        assert_eq!(r.frontmatter.len(), 1);
        assert_eq!(r.frontmatter[0].link_kind.as_str(), "inspired-by");
    }

    #[test]
    fn frontmatter_bare_string_ignored() {
        let md = "---\nextends: Foo\n---\nbody";
        let r = extract(md);
        assert!(r.frontmatter.is_empty(), "bare-string YAML must not be treated as a link");
    }

    #[test]
    fn frontmatter_malformed_yaml_sets_flag() {
        let md = "---\nextends: [[Foo\nthis is not yaml: : :\n---\nbody";
        let r = extract(md);
        assert!(r.frontmatter_parse_error);
        // Body still parses normally.
        assert!(r.body.is_empty());
    }

    #[test]
    fn body_skips_empty_wikilinks() {
        let r = extract("[[]] and [[ ]] and [[Foo]]");
        // Only [[Foo]] is recorded.
        assert_eq!(r.body.len(), 1);
        assert_eq!(r.body[0].link_text, "Foo");
    }

    #[test]
    fn open_questions_heading_sets_flag() {
        let r = extract("body\n\n## Open questions\n\nis this a thing?");
        assert!(r.has_open_questions);
    }

    #[test]
    fn duplicate_wikilinks_have_distinct_positions() {
        let r = extract("[[Foo]] then [[Foo]] again");
        assert_eq!(r.body.len(), 2);
        assert_ne!(r.body[0].position, r.body[1].position);
    }

    #[test]
    fn long_input_is_linear_time() {
        let chunk = "blah ".repeat(2000); // ~10k chars
        let mut md = String::new();
        for _ in 0..5 {
            md.push_str(&chunk);
            md.push_str("[[Target]] ");
        }
        let start = std::time::Instant::now();
        let r = extract(&md);
        let elapsed = start.elapsed();
        assert_eq!(r.body.len(), 5);
        assert!(elapsed.as_millis() < 200, "extractor too slow: {:?}", elapsed);
    }

    // ---------- WI #141: frontmatter positions are each link's own token ----------

    /// Expected frontmatter links as `(kind, nth occurrence of the needle)`.
    type Wi141Own = &'static [(&'static str, usize)];

    /// Byte offsets of every occurrence of `needle` in `md`, in order.
    fn wi141_offsets(md: &str, needle: &str) -> Vec<i64> {
        md.match_indices(needle).map(|(i, _)| i as i64).collect()
    }

    /// The frontmatter links as sorted `(kind, position)` pairs.
    fn wi141_fm_kind_positions(r: &ExtractedLinks) -> Vec<(String, i64)> {
        let mut got: Vec<(String, i64)> = r
            .frontmatter
            .iter()
            .map(|l| (l.link_kind.as_str().to_string(), l.position))
            .collect();
        got.sort();
        got
    }

    /// `expected` names each link by kind and by which occurrence of `needle`
    /// in `md` (0-based) is its own token.
    fn wi141_assert_own_tokens(case: &str, md: &str, needle: &str, expected: &[(&str, usize)]) {
        let r = extract(md);
        assert!(!r.frontmatter_parse_error, "{case}: frontmatter must parse");
        let offsets = wi141_offsets(md, needle);
        let mut want: Vec<(String, i64)> = expected
            .iter()
            .map(|(kind, nth)| ((*kind).to_string(), offsets[*nth]))
            .collect();
        want.sort();
        assert_eq!(
            wi141_fm_kind_positions(&r),
            want,
            "{case}: each frontmatter link sits at its own token in {md:?}"
        );
    }

    /// Every link on the note (body and frontmatter) has a distinct position.
    fn wi141_assert_all_positions_distinct(case: &str, r: &ExtractedLinks) {
        let mut all: Vec<i64> = r.all().map(|l| l.position).collect();
        let n = all.len();
        all.sort_unstable();
        all.dedup();
        assert_eq!(all.len(), n, "{case}: positions must be unique: {r:?}");
    }

    #[test]
    fn frontmatter_same_target_under_two_kinds_gets_own_token_positions() {
        let md = "---\nextends:\n  - [[Alpha]]\ncontradicts:\n  - [[Alpha]]\n---\nbody";
        wi141_assert_own_tokens(
            "two kinds",
            md,
            "[[Alpha]]",
            &[("extends", 0), ("contradicts", 1)],
        );
    }

    #[test]
    fn frontmatter_same_target_under_four_kinds_gets_four_distinct_positions() {
        let md = "---\nextends:\n  - [[Alpha]]\ncontradicts:\n  - [[Alpha]]\n\
                  example-of:\n  - [[Alpha]]\ninspired-by:\n  - [[Alpha]]\n---\nbody\n";
        wi141_assert_own_tokens(
            "four kinds",
            md,
            "[[Alpha]]",
            &[
                ("extends", 0),
                ("contradicts", 1),
                ("example-of", 2),
                ("inspired-by", 3),
            ],
        );
    }

    #[test]
    fn frontmatter_hand_written_link_repeated_under_two_keys_gets_own_positions() {
        // The WI's hand-written `memex add` body: `notes` is a valid
        // user-defined kind, so both keys yield a link.
        let md = "---\nnotes: see [[Alpha]]\nextends:\n  - [[Alpha]]\n---\nbody";
        wi141_assert_own_tokens(
            "notes + extends",
            md,
            "[[Alpha]]",
            &[("notes", 0), ("extends", 1)],
        );
    }

    #[test]
    fn frontmatter_link_ignores_identical_text_under_skipped_keys() {
        let cases: [(&str, &str, Wi141Own); 7] = [
            (
                "about above",
                "---\nabout: [[Alpha]]\nextends:\n  - [[Alpha]]\n---\nbody",
                &[("extends", 1)],
            ),
            (
                "from-day above",
                "---\nfrom-day: [[Alpha]]\nextends:\n  - [[Alpha]]\n---\nbody",
                &[("extends", 1)],
            ),
            (
                "invalid kind key above",
                "---\n9lives: [[Alpha]]\nextends:\n  - [[Alpha]]\n---\nbody",
                &[("extends", 1)],
            ),
            (
                "non-string key above",
                "---\n42: [[Alpha]]\nextends:\n  - [[Alpha]]\n---\nbody",
                &[("extends", 1)],
            ),
            (
                "nested mapping above",
                "---\nmeta:\n  extends: [[Alpha]]\nextends:\n  - [[Alpha]]\n---\nbody",
                &[("extends", 1)],
            ),
            (
                "about between two kinds",
                "---\nextends: [[Alpha]]\nabout: [[Alpha]]\ncontradicts: [[Alpha]]\n---\nbody",
                &[("extends", 0), ("contradicts", 2)],
            ),
            (
                "about below",
                "---\nextends:\n  - [[Alpha]]\nabout: [[Alpha]]\n---\nbody",
                &[("extends", 0)],
            ),
        ];
        for (case, md, expected) in cases {
            wi141_assert_own_tokens(case, md, "[[Alpha]]", expected);
        }
    }

    #[test]
    fn frontmatter_repeated_token_under_one_key_gets_successive_offsets() {
        let cases: [(&str, &str, Wi141Own); 4] = [
            (
                "quoted flow list",
                "---\nextends: [\"[[A]]\", \"[[A]]\"]\n---\nbody",
                &[("extends", 0), ("extends", 1)],
            ),
            (
                "block list",
                "---\nextends:\n  - [[A]]\n  - [[A]]\n---\nbody",
                &[("extends", 0), ("extends", 1)],
            ),
            (
                "one scalar holding two tokens",
                "---\nextends: \"[[A]] and [[A]]\"\n---\nbody",
                &[("extends", 0), ("extends", 1)],
            ),
            (
                "block list of three after another kind",
                "---\ncontradicts: [[A]]\nextends:\n  - [[A]]\n  - [[A]]\n  - [[A]]\n---\nbody",
                &[
                    ("contradicts", 0),
                    ("extends", 1),
                    ("extends", 2),
                    ("extends", 3),
                ],
            ),
        ];
        for (case, md, expected) in cases {
            wi141_assert_own_tokens(case, md, "[[A]]", expected);
        }
    }

    #[test]
    fn frontmatter_quoted_synonym_and_crlf_keys_point_at_own_tokens() {
        let cases: [(&str, &str, &str, Wi141Own); 6] = [
            (
                "double-quoted keys",
                "---\n\"extends\":\n  - [[Alpha]]\n\"contradicts\": [[Alpha]]\n---\nbody",
                "[[Alpha]]",
                &[("extends", 0), ("contradicts", 1)],
            ),
            (
                "single-quoted key",
                "---\n'extends': [[Alpha]]\ncontradicts: [[Alpha]]\n---\nbody",
                "[[Alpha]]",
                &[("extends", 0), ("contradicts", 1)],
            ),
            (
                "example_of synonym",
                "---\nexample_of: [[Alpha]]\nextends: [[Alpha]]\n---\nbody",
                "[[Alpha]]",
                &[("example-of", 0), ("extends", 1)],
            ),
            (
                "crlf line endings",
                "---\r\nextends:\r\n  - [[Alpha]]\r\ncontradicts:\r\n  - [[Alpha]]\r\n---\r\nbody",
                "[[Alpha]]",
                &[("extends", 0), ("contradicts", 1)],
            ),
            (
                "multibyte title",
                "---\nextends: [[Café]]\ncontradicts: [[Café]]\n---\nbody",
                "[[Café]]",
                &[("extends", 0), ("contradicts", 1)],
            ),
            (
                "labelled then plain",
                "---\nextends: [[Alpha|shown]]\ncontradicts: [[Alpha]]\n\
                 example-of: [[Alpha]]\n---\nb",
                "[[Alpha",
                &[("extends", 0), ("contradicts", 1), ("example-of", 2)],
            ),
        ];
        for (case, md, needle, expected) in cases {
            wi141_assert_own_tokens(case, md, needle, expected);
        }
    }

    #[test]
    fn frontmatter_token_without_verbatim_occurrence_gets_unique_non_token_position() {
        // (case, markdown, needle, kinds whose token has no verbatim
        //  occurrence, verbatim links as (kind, nth occurrence of needle)).
        let cases: [(&str, &str, &str, &[&str], Wi141Own); 4] = [
            (
                "escaped next to a verbatim token",
                "---\nextends: \"\\x5B\\x5BAlpha]]\"\ncontradicts:\n  - [[Alpha]]\n---\nbody",
                "[[Alpha]]",
                &["extends"],
                &[("contradicts", 0)],
            ),
            (
                "two escaped tokens",
                "---\nextends: \"\\x5B\\x5BAlpha]]\"\n\
                 contradicts: \"\\x5B\\x5BAlpha]]\"\n---\nbody",
                "[[Alpha]]",
                &["extends", "contradicts"],
                &[],
            ),
            (
                "folded scalar",
                "---\nextends: >-\n  [[Alpha\n  Beta]]\ncontradicts: [[Alpha Beta]]\n---\nbody",
                "[[Alpha Beta]]",
                &["extends"],
                &[("contradicts", 0)],
            ),
            (
                "escaped with the same link in the body",
                "---\nextends: \"\\x5B\\x5BAlpha]]\"\n---\nSee [[Alpha]] here.\n",
                "[[Alpha]]",
                &["extends"],
                &[],
            ),
        ];
        for (case, md, needle, unverbatim, verbatim) in cases {
            let r = extract(md);
            assert!(!r.frontmatter_parse_error, "{case}: frontmatter must parse");
            assert_eq!(
                r.frontmatter.len(),
                unverbatim.len() + verbatim.len(),
                "{case}: {r:?}"
            );
            wi141_assert_all_positions_distinct(case, &r);
            let offsets = wi141_offsets(md, needle);
            for (kind, nth) in verbatim {
                let l = r
                    .frontmatter
                    .iter()
                    .find(|l| l.link_kind.as_str() == *kind)
                    .unwrap_or_else(|| panic!("{case}: no {kind} link"));
                assert_eq!(l.position, offsets[*nth], "{case}: {kind} at its own token");
            }
            for kind in unverbatim {
                let l = r
                    .frontmatter
                    .iter()
                    .find(|l| l.link_kind.as_str() == *kind)
                    .unwrap_or_else(|| panic!("{case}: no {kind} link"));
                let at = usize::try_from(l.position)
                    .ok()
                    .and_then(|p| md.get(p..))
                    .unwrap_or("");
                assert!(
                    !at.starts_with("[["),
                    "{case}: {kind} has no verbatim token, so its position {} must not \
                     start a `[[` token: {at:?}",
                    l.position
                );
            }
        }
    }

    #[test]
    fn body_positions_keep_regex_offsets_when_frontmatter_repeats_tokens() {
        let md = "---\nextends: [[Alpha]]\ncontradicts: [[Alpha]]\n---\n\
                  See [[Alpha]] and [[Alpha~extends]] and ![[2026-10-01#^ab]].\n";
        let r = extract(md);
        let body_start = md.find("See ").unwrap();
        let want: Vec<(String, i64)> = vec![
            ("references".into(), (body_start + "See ".len()) as i64),
            (
                "extends".into(),
                md.find("[[Alpha~extends]]").unwrap() as i64,
            ),
            ("from-day".into(), md.find("![[2026-10-01").unwrap() as i64),
        ];
        let got: Vec<(String, i64)> = r
            .body
            .iter()
            .map(|l| (l.link_kind.as_str().to_string(), l.position))
            .collect();
        assert_eq!(got, want, "body positions are the regex offsets");
        wi141_assert_all_positions_distinct("body + repeated frontmatter", &r);
    }
}
