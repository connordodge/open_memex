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
        match parse_frontmatter(fm_text, fm_offset, content_md.len()) {
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

/// Frontmatter links, each at the byte offset (in `content_md`) of its own
/// `[[` token; see [`FmPositions`]. `content_len` is `content_md.len()`.
fn parse_frontmatter(
    fm_text: &str,
    fm_offset: usize,
    content_len: usize,
) -> std::result::Result<Vec<PendingLink>, ()> {
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
    let mut positions = FmPositions::new(fm_text, fm_offset, content_len);
    for (key, value) in map {
        let Some(key_str) = key.as_str() else {
            continue;
        };
        // Locate the key's span before any skip, so later keys search after
        // it (`Mapping` keeps the text's key order).
        let mut span = positions.span_of(key_str);
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
        // A skipped key's tokens are still claimed, so no later link takes
        // them when its key has no span of its own.
        if kind_str == LinkKind::FROM_DAY || kind_str == LinkKind::ABOUT {
            positions.reserve_value(&value, &mut span);
            continue;
        }
        let Ok(kind) = LinkKind::new(&kind_str) else {
            positions.reserve_value(&value, &mut span);
            continue;
        };
        collect_wikilinks_from_value(&value, &kind, &mut span, &mut positions, &mut out);
    }
    Ok(out)
}

/// Gives every frontmatter link the byte offset of its own `[[` token.
///
/// The YAML-decoded strings carry no offsets, so each token is found again in
/// the raw frontmatter text, but only inside the span of its own top-level key
/// (from the key to the next top-level key). Within a span, occurrences are
/// claimed in order with a cursor, so a token repeated under one key gets
/// successive offsets; an occurrence on a YAML comment is never claimed.
/// Tokens that yield no link (a skipped key's value, a nested mapping) are
/// claimed too, so a key the line scan missed, which searches the whole
/// frontmatter, never takes them. `serde_yaml::Mapping` keeps key order and sequences keep item order, so
/// decoded order matches text order.
///
/// A token with no verbatim occurrence in its span (an escaped or folded YAML
/// string) gets a position past the end of `content_md`: unique on the note,
/// and never the start of another link's `[[` token, so `update_link` answers
/// `NotFound` for it instead of editing someone else's token.
struct FmPositions<'a> {
    fm_text: &'a str,
    fm_offset: usize,
    /// Top-level keys in text order.
    spans: Vec<KeySpan>,
    /// Index into `spans` where the next key search starts.
    next_span: usize,
    /// Claimed occurrence starts, relative to `fm_text`.
    claimed: std::collections::HashSet<usize>,
    /// Next past-the-end position for a token with no verbatim occurrence.
    next_fallback: usize,
}

/// One top-level key: its decoded name and the byte range of its value,
/// relative to `fm_text` (just after the `:` up to the next top-level key).
struct KeySpan {
    key: String,
    start: usize,
    end: usize,
}

/// Where the next occurrence search starts within a key's span, and where the
/// span ends (both relative to `fm_text`).
struct SpanCursor {
    at: usize,
    end: usize,
}

impl<'a> FmPositions<'a> {
    fn new(fm_text: &'a str, fm_offset: usize, content_len: usize) -> Self {
        Self {
            fm_text,
            fm_offset,
            spans: top_level_key_spans(fm_text),
            next_span: 0,
            claimed: std::collections::HashSet::new(),
            next_fallback: content_len,
        }
    }

    /// The span of the next top-level key named `key`. A key the line scan
    /// could not find (e.g. a flow-mapping frontmatter) searches the whole
    /// frontmatter, still never reusing a claimed occurrence.
    fn span_of(&mut self, key: &str) -> SpanCursor {
        let found = self.spans[self.next_span..]
            .iter()
            .position(|s| s.key == key);
        match found {
            Some(i) => {
                let span = &self.spans[self.next_span + i];
                self.next_span += i + 1;
                SpanCursor {
                    at: span.start,
                    end: span.end,
                }
            }
            None => SpanCursor {
                at: 0,
                end: self.fm_text.len(),
            },
        }
    }

    /// The position (into `content_md`) of `token`'s next unclaimed,
    /// uncommented occurrence in `span`, or a fresh past-the-end position.
    fn claim(&mut self, token: &str, span: &mut SpanCursor) -> i64 {
        match self.take(token, span) {
            Some(p) => (self.fm_offset + p) as i64,
            None => {
                let pos = self.next_fallback;
                self.next_fallback += 1;
                pos as i64
            }
        }
    }

    /// Claims, in text order, every `[[` token in a value that yields no
    /// link (a skipped key's value, a nested mapping), so no later link
    /// claims it. A token with no verbatim occurrence takes no fallback.
    fn reserve_value(&mut self, value: &serde_yaml::Value, span: &mut SpanCursor) {
        use serde_yaml::Value;
        match value {
            Value::String(s) => {
                for m in WIKILINK_RE.find_iter(s) {
                    self.take(m.as_str(), span);
                }
            }
            Value::Sequence(seq) => {
                for v in seq {
                    self.reserve_value(v, span);
                }
            }
            Value::Mapping(map) => {
                for (k, v) in map {
                    self.reserve_value(k, span);
                    self.reserve_value(v, span);
                }
            }
            Value::Tagged(t) => self.reserve_value(&t.value, span),
            _ => {}
        }
    }

    /// Marks `token`'s next unclaimed, uncommented occurrence in `span` as
    /// claimed, moves the cursor past it and returns its start (relative to
    /// `fm_text`).
    fn take(&mut self, token: &str, span: &mut SpanCursor) -> Option<usize> {
        let mut from = span.at;
        while from < span.end {
            let rel = self.fm_text[from..span.end].find(token)?;
            let p = from + rel;
            if !self.claimed.contains(&p) && !in_yaml_comment(self.fm_text, p) {
                self.claimed.insert(p);
                span.at = p + token.len();
                return Some(p);
            }
            // Tokens start with the one-byte `[`, so `p + 1` is a char boundary.
            from = p + 1;
        }
        None
    }
}

/// The top-level keys of a block-mapping frontmatter, in text order. A
/// top-level key line has the indentation of the first content line; other
/// lines at that indentation (`- item`, comments) belong to the key above.
fn top_level_key_spans(fm_text: &str) -> Vec<KeySpan> {
    let mut keys: Vec<(String, usize, usize)> = Vec::new();
    let mut indent: Option<usize> = None;
    let mut line_start = 0;
    while line_start < fm_text.len() {
        let line_end = find_line_end(fm_text, line_start).unwrap_or(fm_text.len());
        let line = fm_text[line_start..line_end].trim_end_matches(['\r', '\n']);
        let trimmed = line.trim_start_matches(' ');
        if !trimmed.is_empty() && !trimmed.starts_with('#') {
            let ind = line.len() - trimmed.len();
            if ind == *indent.get_or_insert(ind) {
                if let Some((key, after_colon)) = parse_key(trimmed) {
                    keys.push((key, line_start, line_start + ind + after_colon));
                }
            }
        }
        line_start = line_end;
    }
    let mut spans = Vec::with_capacity(keys.len());
    for (i, (key, _, start)) in keys.iter().enumerate() {
        let end = keys.get(i + 1).map_or(fm_text.len(), |k| k.1);
        spans.push(KeySpan {
            key: key.clone(),
            start: *start,
            end,
        });
    }
    spans
}

/// The decoded key of a `key: value` line (plain, `"double"` or `'single'`
/// quoted) and the byte offset just past its `:`, or `None` if the line is
/// not a simple mapping key.
fn parse_key(line: &str) -> Option<(String, usize)> {
    let bytes = line.as_bytes();
    let (key, rest) = match bytes.first()? {
        b'"' => {
            let mut key = String::new();
            let mut chars = line[1..].char_indices();
            loop {
                let (i, c) = chars.next()?;
                match c {
                    '"' => break (key, 1 + i + 1),
                    '\\' => key.push(chars.next()?.1),
                    c => key.push(c),
                }
            }
        }
        b'\'' => {
            let mut key = String::new();
            let mut i = 1;
            loop {
                let c = line[i..].chars().next()?;
                if c == '\'' {
                    if line[i + 1..].starts_with('\'') {
                        key.push('\'');
                        i += 2;
                        continue;
                    }
                    break (key, i + 1);
                }
                key.push(c);
                i += c.len_utf8();
            }
        }
        b'-' if matches!(bytes.get(1), None | Some(b' ' | b'\t')) => return None,
        b'?' | b'[' | b'{' | b'&' | b'*' | b'!' | b'|' | b'>' => return None,
        _ => {
            let colon = (0..bytes.len()).find(|&i| {
                bytes[i] == b':' && matches!(bytes.get(i + 1), None | Some(b' ' | b'\t' | b'\r'))
            })?;
            return Some((line[..colon].trim_end().to_string(), colon + 1));
        }
    };
    let after = line.len() - line[rest..].trim_start_matches([' ', '\t']).len();
    line[after..].starts_with(':').then(|| (key, after + 1))
}

/// True when byte `p` of `text` sits in a YAML comment: a `#` at the start of
/// its line or after whitespace, outside quotes and outside a `[[...]]` token
/// (which `quote_bare_wikilinks` quotes before parsing). Quote state is
/// tracked per line.
fn in_yaml_comment(text: &str, p: usize) -> bool {
    let line_start = text[..p].rfind('\n').map_or(0, |i| i + 1);
    let line = &text.as_bytes()[line_start..p];
    let mut in_double = false;
    let mut in_single = false;
    // A quote opens a scalar only at a line start, after whitespace, or after
    // a flow separator; a `#` starts a comment only at a line start or after
    // whitespace.
    let mut at_scalar_start = true;
    let mut after_space = true;
    let mut i = 0;
    while i < line.len() {
        let c = line[i];
        if in_double {
            match c {
                b'\\' => i += 1,
                b'"' => in_double = false,
                _ => {}
            }
        } else if in_single {
            if c == b'\'' {
                if line.get(i + 1) == Some(&b'\'') {
                    i += 1;
                } else {
                    in_single = false;
                }
            }
        } else {
            match c {
                b'#' if after_space => return true,
                b'"' if at_scalar_start => in_double = true,
                b'\'' if at_scalar_start => in_single = true,
                b'[' if line.get(i + 1) == Some(&b'[') => {
                    if let Some(close) = line[i + 2..].windows(2).position(|w| w == b"]]") {
                        i += 2 + close + 2;
                        at_scalar_start = false;
                        after_space = false;
                        continue;
                    }
                }
                _ => {}
            }
        }
        after_space = matches!(c, b' ' | b'\t');
        at_scalar_start = matches!(c, b' ' | b'\t' | b'[' | b'{' | b',');
        i += 1;
    }
    false
}

/// Recursively walk a YAML value collecting `[[Title]]` strings.
/// Bare strings (no `[[...]]` form) are intentionally ignored.
fn collect_wikilinks_from_value(
    value: &serde_yaml::Value,
    kind: &LinkKind,
    span: &mut SpanCursor,
    positions: &mut FmPositions<'_>,
    out: &mut Vec<PendingLink>,
) {
    match value {
        serde_yaml::Value::String(s) => add_fm_links(out, s, kind, span, positions),
        serde_yaml::Value::Sequence(seq) => {
            for v in seq {
                collect_wikilinks_from_value(v, kind, span, positions, out);
            }
        }
        // A nested mapping yields no link; its tokens are still claimed.
        serde_yaml::Value::Mapping(_) => positions.reserve_value(value, span),
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
        // Copy the whole UTF-8 char: `i` is always on a char boundary, since
        // every branch above steps over ASCII bytes or a whole `[[…]]` token.
        let ch = s[i..].chars().next().expect("i is on a char boundary");
        out.push(ch);
        i += ch.len_utf8();
    }
    out
}

/// Scan a frontmatter scalar for `[[Title]]` tokens (only `[[Title]]` form;
/// bare strings are intentionally ignored to avoid silent-rename issues).
fn add_fm_links(
    out: &mut Vec<PendingLink>,
    s: &str,
    kind: &LinkKind,
    span: &mut SpanCursor,
    positions: &mut FmPositions<'_>,
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
        // Position: byte offset of this token's own `[[` within content_md.
        // The match index is into the decoded `s`, which has no offset in the
        // raw text, so the token is claimed again within its key's span.
        let position = positions.claim(cap.get(0).unwrap().as_str(), span);
        out.push(PendingLink {
            link_text: title,
            link_kind: kind.clone(),
            label: alias,
            position,
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

    #[test]
    fn frontmatter_comment_holding_same_token_is_never_claimed() {
        let cases: [(&str, &str, Wi141Own); 4] = [
            (
                "comment line inside the key span",
                "---\nextends:\n  # was [[A]]\n  - [[A]]\n---\nbody",
                &[("extends", 1)],
            ),
            (
                "comment line between two kinds",
                "---\nextends: [[A]]\n# [[A]]\ncontradicts: [[A]]\n---\nbody",
                &[("extends", 0), ("contradicts", 2)],
            ),
            (
                "trailing comment after the token",
                "---\nextends: [[A]] # [[A]]\ncontradicts:\n  - [[A]]\n---\nbody",
                &[("extends", 0), ("contradicts", 2)],
            ),
            (
                "hash inside a token title is not a comment",
                "---\nextends:\n  - [[A #x]]\n  - [[A #x]]\n---\nbody",
                &[("extends", 0), ("extends", 1)],
            ),
        ];
        for (case, md, expected) in cases {
            let needle = if case.starts_with("hash") {
                "[[A #x]]"
            } else {
                "[[A]]"
            };
            wi141_assert_own_tokens(case, md, needle, expected);
        }

        // An escaped token with only a commented verbatim copy gets a
        // past-the-end position, never the comment's `[[`.
        let md = "---\nextends: \"\\x5B\\x5BA]]\" # [[A]]\n---\nbody";
        let r = extract(md);
        assert_eq!(r.frontmatter.len(), 1, "{r:?}");
        assert!(
            r.frontmatter[0].position >= md.len() as i64,
            "commented copy must not be claimed: {r:?}"
        );
    }

    // ---------- WI #145: frontmatter keeps non-ASCII text ----------

    /// A frontmatter link as `(kind, title, label, nth token start)`.
    type Wi145Want = (&'static str, &'static str, Option<&'static str>, usize);

    /// Byte offsets of every `[[` in `md`, in order.
    fn wi145_token_starts(md: &str) -> Vec<i64> {
        md.match_indices("[[").map(|(i, _)| i as i64).collect()
    }

    /// The frontmatter links as `(kind, title, label, position)`, by position.
    fn wi145_fm_links(r: &ExtractedLinks) -> Vec<(String, String, Option<String>, i64)> {
        let mut got: Vec<_> = r
            .frontmatter
            .iter()
            .map(|l| {
                (
                    l.link_kind.as_str().to_string(),
                    l.link_text.clone(),
                    l.label.clone(),
                    l.position,
                )
            })
            .collect();
        got.sort_by_key(|l| l.3);
        got
    }

    #[test]
    fn quote_bare_wikilinks_keeps_non_ascii_text_byte_for_byte() {
        // Text with no bare token comes out exactly as it went in.
        let unchanged: [(&str, &str); 11] = [
            ("latin accents", "title: Ünïcødé\n"),
            ("cjk", "title: 日本語のノート\n"),
            ("emoji", "mood: 😀 happy 🎉\n"),
            ("4-byte chars", "glyphs: 𠜎 𝄞 😀\n"),
            ("double-quoted value", "note: \"Café – crème brûlée\"\n"),
            ("single-quoted value", "note: 'naïve façade l''été'\n"),
            ("non-ascii key", "résumé: oui\n"),
            ("comment", "# été 日本\ntitle: x\n"),
            ("crlf", "title: Ünïcødé\r\nmood: 😀\r\n"),
            ("double-quoted non-ascii token", "extends: \"[[Café]]\"\n"),
            (
                "single-quoted non-ascii token",
                "extends: '[[日本語|ラベル]]'\n",
            ),
        ];
        for (case, input) in unchanged {
            let got = quote_bare_wikilinks(input);
            assert_eq!(
                got.as_bytes(),
                input.as_bytes(),
                "{case}: got {got:?}, want {input:?}"
            );
        }
        // Bare tokens gain quotes; every other byte is kept.
        let quoted: [(&str, &str, &str); 5] = [
            (
                "text around a bare token",
                "notes: «voir» [[Alpha]] — fin\n",
                "notes: «voir» \"[[Alpha]]\" — fin\n",
            ),
            (
                "4-byte chars touching a bare token",
                "x: 😀[[Alpha]]𠜎\n",
                "x: 😀\"[[Alpha]]\"𠜎\n",
            ),
            (
                "bare non-ascii titles",
                "extends: [[Café]]\ncontradicts:\n  - [[日本語]]\n",
                "extends: \"[[Café]]\"\ncontradicts:\n  - \"[[日本語]]\"\n",
            ),
            (
                "bare non-ascii label",
                "extends: [[Alpha|Ünïcode – dash]]\n",
                "extends: \"[[Alpha|Ünïcode – dash]]\"\n",
            ),
            (
                "everything at once",
                "title: Ünïcødé – 日本語 😀 𠜎\nrésumé: \"naïve\"\nextends:\n  - [[Café]]\n\
                 contradicts: '[[日本語]]'\n",
                "title: Ünïcødé – 日本語 😀 𠜎\nrésumé: \"naïve\"\nextends:\n  - \"[[Café]]\"\n\
                 contradicts: '[[日本語]]'\n",
            ),
        ];
        for (case, input, want) in quoted {
            let got = quote_bare_wikilinks(input);
            assert_eq!(
                got.as_bytes(),
                want.as_bytes(),
                "{case}: got {got:?}, want {want:?}"
            );
        }
    }

    #[test]
    fn quote_bare_wikilinks_ascii_output_is_unchanged() {
        let cases: [(&str, &str, &str); 14] = [
            ("empty", "", ""),
            (
                "no tokens",
                "title: plain\ntags: [a, b]\n",
                "title: plain\ntags: [a, b]\n",
            ),
            (
                "bare scalar",
                "extends: [[Foo]]\n",
                "extends: \"[[Foo]]\"\n",
            ),
            (
                "bare list item with kind and alias",
                "extends:\n  - [[Foo~kind|alias]]\n",
                "extends:\n  - \"[[Foo~kind|alias]]\"\n",
            ),
            (
                "two bare tokens in one scalar",
                "notes: see [[Foo]] and [[Bar]]\n",
                "notes: see \"[[Foo]]\" and \"[[Bar]]\"\n",
            ),
            (
                "double-quoted token",
                "extends: \"[[Foo]]\"\n",
                "extends: \"[[Foo]]\"\n",
            ),
            (
                "single-quoted token",
                "extends: '[[Foo]]'\n",
                "extends: '[[Foo]]'\n",
            ),
            (
                "flow list mixing quoted and bare",
                "extends: [\"[[Foo]]\", [[Bar]]]\n",
                "extends: [\"[[Foo]]\", \"[[Bar]]\"]\n",
            ),
            (
                "internal double quotes are escaped",
                "extends: [[A \"b\" c]]\n",
                "extends: \"[[A \\\"b\\\" c]]\"\n",
            ),
            (
                "unclosed token on its line",
                "extends: [[Foo\nx: y]]\n",
                "extends: [[Foo\nx: y]]\n",
            ),
            (
                "crlf",
                "extends: [[Foo]]\r\ncontradicts: [[Bar]]\r\n",
                "extends: \"[[Foo]]\"\r\ncontradicts: \"[[Bar]]\"\r\n",
            ),
            (
                "comment holding a token",
                "# old [[Foo]]\nextends: [[Bar]]\n",
                "# old \"[[Foo]]\"\nextends: \"[[Bar]]\"\n",
            ),
            (
                "apostrophe opens single-quote state",
                "notes: it's [[Foo]]\n",
                "notes: it's [[Foo]]\n",
            ),
            ("empty token", "x: [[]]\n", "x: \"[[]]\"\n"),
        ];
        for (case, input, want) in cases {
            assert_eq!(quote_bare_wikilinks(input), want, "{case}");
        }
    }

    #[test]
    fn frontmatter_with_non_ascii_title_parses_and_indexes_extends_link() {
        let md = "---\ntitle: Ünïcødé\nextends:\n  - [[Alpha]]\n---\nbody";
        let r = extract(md);
        assert!(!r.frontmatter_parse_error, "frontmatter must parse: {r:?}");
        assert_eq!(
            wi145_fm_links(&r),
            vec![(
                "extends".to_string(),
                "Alpha".to_string(),
                None,
                md.find("[[Alpha]]").unwrap() as i64,
            )]
        );
    }

    #[test]
    fn frontmatter_non_ascii_text_keeps_titles_labels_and_token_positions() {
        let cases: [(&str, &str, &[Wi145Want]); 8] = [
            (
                "latin title above two keys",
                "---\ntitle: Ünïcødé\nextends:\n  - [[Alpha]]\ncontradicts: [[Alpha]]\n---\nbody",
                &[
                    ("extends", "Alpha", None, 0),
                    ("contradicts", "Alpha", None, 1),
                ],
            ),
            (
                "cjk and emoji before tokens on one line",
                "---\nnotes: 日本語 😀 see [[Alpha]] and [[Café]]\n---\nb",
                &[("notes", "Alpha", None, 0), ("notes", "Café", None, 1)],
            ),
            (
                "4-byte chars touching quoted tokens",
                "---\nnotes: \"𠜎[[Alpha]]𝄞[[Beta]]\"\n---\nb",
                &[("notes", "Alpha", None, 0), ("notes", "Beta", None, 1)],
            ),
            (
                "bare non-ascii titles",
                "---\nextends: [[Café]]\ncontradicts:\n  - [[日本語]]\n---\nb",
                &[
                    ("extends", "Café", None, 0),
                    ("contradicts", "日本語", None, 1),
                ],
            ),
            (
                "quoted non-ascii titles after a quoted non-ascii value",
                "---\nsummary: \"Crème – brûlée\"\nextends: [\"[[Café]]\", '[[日本語]]']\n---\nb",
                &[("extends", "Café", None, 0), ("extends", "日本語", None, 1)],
            ),
            (
                "non-ascii labels bare and quoted",
                "---\nextends: [[Alpha|Ünïcode – dash]]\ncontradicts: \"[[Alpha|日本語 😀]]\"\n---\nb",
                &[
                    ("extends", "Alpha", Some("Ünïcode – dash"), 0),
                    ("contradicts", "Alpha", Some("日本語 😀"), 1),
                ],
            ),
            (
                "crlf with accents",
                "---\r\ntitle: Ünïcødé\r\nextends:\r\n  - [[Café]]\r\n---\r\nbody",
                &[("extends", "Café", None, 0)],
            ),
            (
                "non-ascii comment and key above",
                "---\n# été 😀\nrésumé: oui\nexample-of: '[[Café|crème]]'\n---\nb",
                &[("example-of", "Café", Some("crème"), 0)],
            ),
        ];
        for (case, md, expected) in cases {
            let r = extract(md);
            assert!(!r.frontmatter_parse_error, "{case}: frontmatter must parse");
            let starts = wi145_token_starts(md);
            let want: Vec<(String, String, Option<String>, i64)> = expected
                .iter()
                .map(|(kind, title, label, nth)| {
                    (
                        (*kind).to_string(),
                        (*title).to_string(),
                        label.map(str::to_string),
                        starts[*nth],
                    )
                })
                .collect();
            assert_eq!(wi145_fm_links(&r), want, "{case}: {md:?}");
        }
    }

    #[test]
    fn frontmatter_flow_mapping_non_ascii_skipped_value_keeps_link_byte_offsets() {
        // #141's reserve_value path: a skipped key's (or nested mapping's)
        // multibyte text before a link still leaves each link at the byte
        // offset of its own `[[`.
        let cases: [(&str, &str, Wi141At); 6] = [
            (
                "about with accents first",
                "---\n{about: \"Ünïcødé [[A]]\", extends: [[A]]}\n---\nb",
                &[("extends", "[[A]]", 1)],
            ),
            (
                "from-day cjk token first",
                "---\n{from-day: [[日本語]], extends: [[日本語]], contradicts: \"😀 [[日本語]]\"}\n---\nb",
                &[("extends", "[[日本語]]", 1), ("contradicts", "[[日本語]]", 2)],
            ),
            (
                "invalid kind with emoji",
                "---\n{9lives: \"😀 [[Café]]\", extends: [[Café]]}\n---\nb",
                &[("extends", "[[Café]]", 1)],
            ),
            (
                "nested mapping with 4-byte text",
                "---\n{meta: {k: \"𠜎 [[A]]\"}, extends: [[A]]}\n---\nb",
                &[("extends", "[[A]]", 1)],
            ),
            (
                "skipped value with a non-ascii label",
                "---\n{about: [[A|Ünïcode – dash]], extends: \"𝄞 [[A|Ünïcode – dash]]\"}\n---\nb",
                &[("extends", "[[A|Ünïcode – dash]]", 1)],
            ),
            (
                "block style about with cjk title above",
                "---\ntitle: 日本語\nabout: \"é [[A]]\"\nextends: [[A]]\n---\nb",
                &[("extends", "[[A]]", 1)],
            ),
        ];
        for (case, md, expected) in cases {
            wi141_assert_fm_at(case, md, expected);
            let r = extract(md);
            for l in &r.frontmatter {
                let p = l.position as usize;
                assert!(
                    md.is_char_boundary(p) && md[p..].starts_with("[["),
                    "{case}: {} link at {p} is not a `[[` byte offset",
                    l.link_kind.as_str()
                );
            }
        }
        // Titles and labels decode intact on this path too.
        let r = extract(
            "---\n{about: [[A|Ünïcode – dash]], extends: \"𝄞 [[A|Ünïcode – dash]]\"}\n---\nb",
        );
        assert_eq!(r.frontmatter.len(), 1, "{r:?}");
        assert_eq!(r.frontmatter[0].link_text, "A");
        assert_eq!(r.frontmatter[0].label.as_deref(), Some("Ünïcode – dash"));
    }

    #[test]
    fn quote_bare_wikilinks_pins_ascii_scanner_quirks() {
        // Pinned current behaviour: the scanner tracks quote state with no
        // escape handling and matches the first `]]` on the line.
        let cases: [(&str, &str, &str); 9] = [
            (
                "backslash-escaped quote toggles double-quote state",
                "x: \"a \\\" [[Foo]]\"\n",
                "x: \"a \\\" \"[[Foo]]\"\"\n",
            ),
            (
                "apostrophe inside double quotes is ignored",
                "x: \"it's\" [[Foo]]\n",
                "x: \"it's\" \"[[Foo]]\"\n",
            ),
            (
                "double quote inside single quotes is ignored",
                "x: 'say \"hi' [[Foo]]\n",
                "x: 'say \"hi' \"[[Foo]]\"\n",
            ),
            (
                "doubled apostrophe keeps single-quote state",
                "x: 'it''s [[Foo]]'\n",
                "x: 'it''s [[Foo]]'\n",
            ),
            (
                "third closing bracket stays outside",
                "x: [[Foo]]]\n",
                "x: \"[[Foo]]\"]\n",
            ),
            (
                "nested opener joins one token",
                "x: [[a [[b]]\n",
                "x: \"[[a [[b]]\"\n",
            ),
            (
                "single bracket before a token",
                "x: [ [[Foo]] ]\n",
                "x: [ \"[[Foo]]\" ]\n",
            ),
            ("token at end of input", "x: [[Foo]]", "x: \"[[Foo]]\""),
            ("opener at end of input", "x: [[", "x: [["),
        ];
        for (case, input, want) in cases {
            assert_eq!(quote_bare_wikilinks(input), want, "{case}");
        }
    }

    // ---------- WI #141 verify: every `FmPositions` branch ----------

    /// Expected frontmatter links as `(kind, needle, nth occurrence of needle)`.
    type Wi141At = &'static [(&'static str, &'static str, usize)];

    /// Each frontmatter link sits at the `nth` occurrence of its `needle` in
    /// `md`, and every position on the note is distinct.
    fn wi141_assert_fm_at(case: &str, md: &str, expected: &[(&str, &str, usize)]) {
        let r = extract(md);
        assert!(!r.frontmatter_parse_error, "{case}: frontmatter must parse");
        let mut want: Vec<(String, i64)> = expected
            .iter()
            .map(|(kind, needle, nth)| {
                let at = wi141_offsets(md, needle);
                assert!(*nth < at.len(), "{case}: fixture lacks {needle} #{nth}");
                ((*kind).to_string(), at[*nth])
            })
            .collect();
        want.sort();
        assert_eq!(
            wi141_fm_kind_positions(&r),
            want,
            "{case}: each frontmatter link sits at its own token in {md:?}"
        );
        wi141_assert_all_positions_distinct(case, &r);
    }

    #[test]
    fn frontmatter_key_scan_finds_spaced_quoted_escaped_and_indented_keys() {
        // A skipped `about: [[A]]` sits above each kind key: if the line scan
        // misses the kind key, the whole-frontmatter fallback claims the
        // `about` token instead of the link's own.
        let cases: [(&str, &str, Wi141At); 10] = [
            (
                "plain key with a space before the colon",
                "---\nabout: [[A]]\nextends : [[A]]\n---\nb",
                &[("extends", "[[A]]", 1)],
            ),
            (
                "tab after the colon",
                "---\nabout: [[A]]\nextends:\t[[A]]\n---\nb",
                &[("extends", "[[A]]", 1)],
            ),
            (
                "double-quoted key with a space before the colon",
                "---\nabout: [[A]]\n\"extends\" : [[A]]\n---\nb",
                &[("extends", "[[A]]", 1)],
            ),
            (
                "double-quoted key holding an escape",
                "---\nabout: [[A]]\n\"inspired\\ by\": [[A]]\n---\nb",
                &[("inspired-by", "[[A]]", 1)],
            ),
            (
                "single-quoted key holding a space",
                "---\nabout: [[A]]\n'inspired by': [[A]]\n---\nb",
                &[("inspired-by", "[[A]]", 1)],
            ),
            (
                "indented frontmatter",
                "---\n  about: [[A]]\n  extends: [[A]]\n---\nb",
                &[("extends", "[[A]]", 1)],
            ),
            (
                "blank and indented comment lines before the first key",
                "---\n  \n  # [[A]]\nabout: [[A]]\nextends:\n  - [[A]]\n---\nb",
                &[("extends", "[[A]]", 2)],
            ),
            (
                "top-level comment shaped like a key inside a span",
                "---\nabout: [[A]]\nextends:\n# todo: more\n  - [[A]]\n---\nb",
                &[("extends", "[[A]]", 1)],
            ),
            (
                "zero-indented sequence item shaped like a key",
                "---\nabout: [[A]]\nextends:\n- note: x\n- [[A]]\n---\nb",
                &[("extends", "[[A]]", 1)],
            ),
            (
                "key after a skipped nested mapping",
                "---\nabout:\n  extends: [[A]]\n  more: [[A]]\nextends: [[A]]\n---\nb",
                &[("extends", "[[A]]", 2)],
            ),
        ];
        for (case, md, expected) in cases {
            wi141_assert_fm_at(case, md, expected);
        }
    }

    #[test]
    fn frontmatter_comment_detection_respects_quotes_escapes_and_separators() {
        let cases: [(&str, &str, Wi141At); 10] = [
            (
                "single-quoted scalar with an escaped quote",
                "---\nextends: 'it''s # [[A]]'\ncontradicts: [[A]]\n---\nb",
                &[("extends", "[[A]]", 0), ("contradicts", "[[A]]", 1)],
            ),
            (
                "double-quoted scalar with escaped quotes",
                "---\nextends: \"a \\\" b \\\" # [[A]]\"\ncontradicts: [[A]]\n---\nb",
                &[("extends", "[[A]]", 0), ("contradicts", "[[A]]", 1)],
            ),
            (
                "quote right after a flow sequence opens",
                "---\nextends: ['x # [[A]]', [[A]]]\n---\nb",
                &[("extends", "[[A]]", 0), ("extends", "[[A]]", 1)],
            ),
            (
                "quote right after a flow comma",
                "---\nextends: [\"b\",'x # [[A]]']\ncontradicts: [[A]]\n---\nb",
                &[("extends", "[[A]]", 0), ("contradicts", "[[A]]", 1)],
            ),
            (
                "quote right after a tab",
                "---\nextends:\t'x # [[A]]'\ncontradicts: [[A]]\n---\nb",
                &[("extends", "[[A]]", 0), ("contradicts", "[[A]]", 1)],
            ),
            (
                "apostrophe inside a word opens no quote",
                "---\nextends:\n  - don't # [[A]] it's\n  - [[A]]\n---\nb",
                &[("extends", "[[A]]", 1)],
            ),
            (
                "double quote inside a word opens no quote",
                "---\nextends:\n  - say\"hi # [[A]] \"\n  - [[A]]\n---\nb",
                &[("extends", "[[A]]", 1)],
            ),
            (
                "hash after a tab starts a comment",
                "---\nextends:\t# [[A]]\n  - [[A]]\n---\nb",
                &[("extends", "[[A]]", 1)],
            ),
            (
                "hash glued to a word is not a comment",
                "---\nextends: see#[[A]]\ncontradicts: [[A]]\n---\nb",
                &[("extends", "[[A]]", 0), ("contradicts", "[[A]]", 1)],
            ),
            (
                "token after a token holding a hash",
                "---\nextends: [ [[A #x]], [[A #x]] ]\n---\nb",
                &[("extends", "[[A #x]]", 0), ("extends", "[[A #x]]", 1)],
            ),
        ];
        for (case, md, expected) in cases {
            wi141_assert_fm_at(case, md, expected);
        }
    }

    #[test]
    fn frontmatter_cursor_claims_after_the_previous_token_in_its_span() {
        // The `{k: [[A]]}` item is a mapping, which yields no link. The cursor
        // sits past `[[B]]` when `[[A]]` is claimed, so `[[A]]` gets the third
        // item's token, not the mapping's.
        let md = "---\nextends:\n  - {k: [[A]]}\n  - [[B]]\n  - [[A]]\n---\nb";
        wi141_assert_fm_at(
            "cursor",
            md,
            &[("extends", "[[B]]", 0), ("extends", "[[A]]", 1)],
        );
    }

    #[test]
    fn frontmatter_unscanned_key_searches_whole_frontmatter_without_reusing_claims() {
        // Keys the line scan cannot find (a flow-mapping frontmatter, an
        // anchored key) search the whole frontmatter and skip claimed tokens.
        let cases: [(&str, &str, Wi141At); 3] = [
            (
                "flow mapping, two kinds",
                "---\n{extends: [[A]], contradicts: [[A]]}\n---\nb",
                &[("extends", "[[A]]", 0), ("contradicts", "[[A]]", 1)],
            ),
            (
                "flow mapping, three kinds",
                "---\n{extends: [[A]], contradicts: [[A]], example-of: [[A]]}\n---\nb",
                &[
                    ("extends", "[[A]]", 0),
                    ("contradicts", "[[A]]", 1),
                    ("example-of", "[[A]]", 2),
                ],
            ),
            (
                "anchored key after a scanned key",
                "---\nextends: [[A]]\n&k contradicts: [[A]]\n---\nb",
                &[("extends", "[[A]]", 0), ("contradicts", "[[A]]", 1)],
            ),
        ];
        for (case, md, expected) in cases {
            wi141_assert_fm_at(case, md, expected);
        }
    }

    #[test]
    fn frontmatter_flow_mapping_link_never_claims_a_skipped_key_token() {
        // Lead ruling: a link never claims a skipped key's identical token
        // when its own occurrence exists, in a flow-mapping frontmatter too.
        let cases: [(&str, &str, Wi141At); 2] = [
            (
                "about first",
                "---\n{about: [[A]], extends: [[A]]}\n---\nb",
                &[("extends", "[[A]]", 1)],
            ),
            (
                "from-day first",
                "---\n{from-day: [[A]], extends: [[A]], contradicts: [[A]]}\n---\nb",
                &[("extends", "[[A]]", 1), ("contradicts", "[[A]]", 2)],
            ),
        ];
        for (case, md, expected) in cases {
            wi141_assert_fm_at(case, md, expected);
        }
    }

    #[test]
    fn frontmatter_unverbatim_token_never_claims_a_later_key_token() {
        // The escaped token's span ends at the next key, so it never reaches
        // the skipped `about` token below it.
        let md = "---\nextends: \"\\x5B\\x5BA]]\"\nabout: [[A]]\n---\nb";
        let r = extract(md);
        assert_eq!(r.frontmatter.len(), 1, "{r:?}");
        assert_eq!(r.frontmatter[0].position, md.len() as i64, "{r:?}");
    }

    #[test]
    fn frontmatter_block_scalar_line_starting_with_hash_gets_fallback_position() {
        // Pinned current behaviour (WI #141 open risk): a `|` block-scalar
        // line whose content starts with `#` reads as a comment, so its token
        // gets a past-the-end position; the next key still gets its own token.
        let md = "---\nextends: |\n  # [[A]]\ncontradicts: [[A]]\n---\nb";
        let r = extract(md);
        assert!(!r.frontmatter_parse_error);
        let pos = |kind: &str| {
            r.frontmatter
                .iter()
                .find(|l| l.link_kind.as_str() == kind)
                .unwrap_or_else(|| panic!("no {kind} link: {r:?}"))
                .position
        };
        assert_eq!(pos("extends"), md.len() as i64, "{r:?}");
        assert_eq!(pos("contradicts"), wi141_offsets(md, "[[A]]")[1], "{r:?}");
    }

    #[test]
    fn frontmatter_flow_mapping_nested_mapping_token_is_reserved() {
        // `reserve_value` contract: a nested mapping yields no link, but its
        // tokens (keys and values) are claimed, so a later link in a
        // flow-mapping frontmatter takes its own occurrence.
        let cases: [(&str, &str, Wi141At); 3] = [
            (
                "nested mapping under a kind key",
                "---\n{extends: {k: [[A]]}, contradicts: [[A]]}\n---\nb",
                &[("contradicts", "[[A]]", 1)],
            ),
            (
                "nested mapping under a skipped key",
                "---\n{about: {k: [[A]]}, extends: [[A]]}\n---\nb",
                &[("extends", "[[A]]", 1)],
            ),
            (
                "quoted token as a nested mapping key",
                "---\n{extends: {\"[[A]]\": x}, contradicts: [[A]]}\n---\nb",
                &[("contradicts", "[[A]]", 1)],
            ),
        ];
        for (case, md, expected) in cases {
            wi141_assert_fm_at(case, md, expected);
        }
    }

    #[test]
    fn frontmatter_flow_mapping_invalid_kind_key_token_is_reserved() {
        // A key whose kind fails validation is skipped, and its token is
        // still claimed, so the later link takes its own occurrence.
        let cases: [(&str, &str, Wi141At); 2] = [
            (
                "invalid kind first",
                "---\n{\"bad kind!\": [[A]], extends: [[A]]}\n---\nb",
                &[("extends", "[[A]]", 1)],
            ),
            (
                "invalid kind sequence first",
                "---\n{\"bad kind!\": [\"[[A]]\", \"[[A]]\"], extends: [[A]]}\n---\nb",
                &[("extends", "[[A]]", 2)],
            ),
        ];
        for (case, md, expected) in cases {
            wi141_assert_fm_at(case, md, expected);
        }
    }

    #[test]
    fn frontmatter_skipped_token_without_verbatim_occurrence_takes_no_fallback() {
        // `reserve_value` contract: a skipped token with no verbatim
        // occurrence takes no fallback position, so the first link that
        // needs one still gets `content_md.len()`.
        let cases: [(&str, &str); 3] = [
            (
                "skipped about",
                "---\nabout: \"\\x5B\\x5BA]]\"\nextends: \"\\x5B\\x5BB]]\"\n---\nb",
            ),
            (
                "skipped invalid kind",
                "---\n\"bad kind!\": \"\\x5B\\x5BA]]\"\nextends: \"\\x5B\\x5BB]]\"\n---\nb",
            ),
            (
                "nested mapping",
                "---\nextends:\n  - {k: \"\\x5B\\x5BA]]\"}\n  - \"\\x5B\\x5BB]]\"\n---\nb",
            ),
        ];
        for (case, md) in cases {
            let r = extract(md);
            assert!(!r.frontmatter_parse_error, "{case}: frontmatter must parse");
            assert_eq!(r.frontmatter.len(), 1, "{case}: {r:?}");
            assert_eq!(
                r.frontmatter[0].position,
                md.len() as i64,
                "{case}: the link takes the first fallback position: {r:?}"
            );
        }
    }
}
