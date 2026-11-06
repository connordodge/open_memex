//! WI #236 (T1): the tag grammar and extractor (Spec #234 R4-R8, R20; rulings
//! D13, D16, D17).
//!
//! The grammar contract lives in `app/test/fixtures/tags/grammar.json`, which
//! the Dart port (#245) reads too, so both languages are held to one table.
//! The tests below the fixture test pin each rule on its own, both arms, so a
//! fixture row that drifts still has a named test behind it.
//!
//! API under test (frozen, `crates/memex-core/src/tags.rs`):
//!   pub struct ExtractedTag { pub name: String, pub first_line: String }
//!   pub fn extract(person_text: &str) -> Vec<ExtractedTag>
//!   pub fn person_section(body: &str) -> &str
//!   pub fn normalize_name(input: &str) -> Option<String>
//!   pub fn is_system_tag(name: &str) -> bool

use std::collections::BTreeSet;
use std::path::PathBuf;

use memex_core::daily::{split_body, TOPICS_MARKER};
use memex_core::tags::{extract, is_system_tag, normalize_name, person_section, ExtractedTag};
use serde_json::Value;

fn grammar_path() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../app/test/fixtures/tags/grammar.json")
}

fn grammar() -> Value {
    let path = grammar_path();
    let raw =
        std::fs::read_to_string(&path).unwrap_or_else(|e| panic!("read {}: {e}", path.display()));
    serde_json::from_str(&raw).expect("grammar.json is JSON")
}

fn str_list(v: &Value, what: &str) -> Vec<String> {
    v.as_array()
        .unwrap_or_else(|| panic!("{what} is an array"))
        .iter()
        .map(|s| {
            s.as_str()
                .unwrap_or_else(|| panic!("{what} holds strings"))
                .to_string()
        })
        .collect()
}

fn fixture_system_tags() -> Vec<String> {
    str_list(&grammar()["system_tags"], "system_tags")
}

/// The extracted names of `text`, in the order `extract` returns them.
fn names(text: &str) -> Vec<String> {
    extract(text).into_iter().map(|t| t.name).collect()
}

fn tag(name: &str, first_line: &str) -> ExtractedTag {
    ExtractedTag {
        name: name.to_string(),
        first_line: first_line.to_string(),
    }
}

/// Asserts each `(input, expected names)` pair, reporting every mismatch.
fn assert_names(cases: &[(&str, &[&str])]) {
    let mut failures = Vec::new();
    for (input, expected) in cases {
        let got = names(input);
        if got != *expected {
            failures.push(format!("{input:?}: expected {expected:?}, got {got:?}"));
        }
    }
    assert!(
        failures.is_empty(),
        "{} case(s) failed:\n{}",
        failures.len(),
        failures.join("\n")
    );
}

// ---------- AC 1: the shared fixture ----------

#[test]
fn grammar_fixture_rows_all_pass() {
    let g = grammar();

    // The system tag list is in the fixture (D17).
    let system = fixture_system_tags();
    assert!(!system.is_empty(), "grammar.json lists the system tags");

    let cases = g["cases"]
        .as_array()
        .expect("grammar.json has a cases array");
    assert!(cases.len() >= 40, "one row per grammar rule and edge case");

    // One row per rule of R4-R6 and the WI's ACs.
    let rules: BTreeSet<String> = cases
        .iter()
        .map(|c| {
            c["rule"]
                .as_str()
                .expect("every case has a rule")
                .to_string()
        })
        .collect();
    for required in [
        "opener",
        "first-char",
        "body-chars",
        "trailing",
        "case",
        "combining",
        "stop",
        "heading",
        "excluded-code-span",
        "excluded-fence",
        "excluded-url",
        "excluded-wikilink",
        "excluded-transclusion",
        "excluded-markdown-link",
        "system",
    ] {
        assert!(
            rules.contains(required),
            "grammar.json has a {required} row"
        );
    }

    let mut failures = Vec::new();
    let mut positive = 0;
    for c in cases {
        let name = c["name"].as_str().expect("every case has a name");
        let input = c["input"].as_str().expect("every case has a string input");
        let expected = str_list(&c["tags"], "tags");
        // The table itself lists names sorted and once each, as extract does.
        let mut canonical = expected.clone();
        canonical.sort();
        canonical.dedup();
        assert_eq!(
            expected, canonical,
            "case {name:?}: tags are sorted and unique"
        );
        if !expected.is_empty() {
            positive += 1;
        }
        let got = names(input);
        if got != expected {
            failures.push(format!(
                "{name} ({input:?}): expected {expected:?}, got {got:?}"
            ));
        }
    }
    assert!(positive >= 20, "the table holds positive rows too");
    assert!(
        failures.is_empty(),
        "{} of {} grammar.json rows failed:\n{}",
        failures.len(),
        cases.len(),
        failures.join("\n")
    );
}

// ---------- AC 2: where a tag starts and what it holds ----------

#[test]
fn hash_starts_a_tag_only_at_line_start_whitespace_or_an_opening_bracket_or_quote() {
    assert_names(&[
        // Line start, including after a newline and indentation.
        ("#work", &["work"]),
        ("first\n#work", &["work"]),
        ("first\r\n#work\r\n", &["work"]),
        ("   #work", &["work"]),
        // Whitespace.
        ("note #work", &["work"]),
        ("note\t#work", &["work"]),
        // Each opening bracket and quote.
        ("x (#work)", &["work"]),
        ("x [#work]", &["work"]),
        ("x {#work}", &["work"]),
        ("x \"#work\"", &["work"]),
        ("x '#work'", &["work"]),
        // Anything else before the hash.
        ("a#b", &[]),
        ("1#b", &[]),
        ("(a)#b", &[]),
        ("x]#b", &[]),
        ("x}#b", &[]),
        ("x.#b", &[]),
        ("x-#b", &[]),
        ("x_#b", &[]),
        ("x/#b", &[]),
        ("\\#b", &[]),
        ("#work#play", &["work"]),
        // Then a Unicode letter.
        ("#123", &[]),
        ("#1a", &[]),
        ("#_a", &[]),
        ("#-a", &[]),
        ("#\u{301}a", &[]),
        ("#a1", &["a1"]),
        ("#\u{65e5}\u{672c}", &["\u{65e5}\u{672c}"]),
        ("#\u{e9}", &["\u{e9}"]),
    ]);
}

#[test]
fn tag_name_continues_with_letters_marks_decimal_digits_dash_and_underscore() {
    assert_names(&[
        ("#q3-plan", &["q3-plan"]),
        ("#my_tag", &["my_tag"]),
        ("#a1b2", &["a1b2"]),
        // \p{Nd} beyond ASCII (ARABIC-INDIC DIGIT THREE).
        ("#q\u{663}", &["q\u{663}"]),
        // \p{No} is not a decimal digit (SUPERSCRIPT TWO).
        ("#x\u{b2}", &["x"]),
        // \p{M} mid name.
        ("#cafe\u{301}-time", &["cafe\u{301}-time"]),
        // Anything else ends the name.
        ("#work.", &["work"]),
        ("#work,", &["work"]),
        ("#work!", &["work"]),
        ("#work:", &["work"]),
        ("#work'", &["work"]),
        ("#work)", &["work"]),
        ("#work\u{1F600}", &["work"]),
        ("#work plan", &["work"]),
    ]);
}

// ---------- AC 3: trailing - and _ ----------

#[test]
fn trailing_dash_or_underscore_is_not_part_of_the_name() {
    assert_names(&[
        ("#plan-", &["plan"]),
        ("#a_", &["a"]),
        ("#plan--", &["plan"]),
        ("#a-_", &["a"]),
        ("#a_-", &["a"]),
        ("#q3-plan-", &["q3-plan"]),
        ("#plan- next", &["plan"]),
        ("(#plan_)", &["plan"]),
        // Inner ones stay.
        ("#a-b", &["a-b"]),
        ("#a_b", &["a_b"]),
        ("#a--b", &["a--b"]),
    ]);
}

// ---------- AC 4: lowercase, one per name ----------

#[test]
fn names_are_lowercase_and_one_per_name() {
    assert_names(&[
        ("#work #Work", &["work"]),
        ("#WORK", &["work"]),
        ("#R\u{c9}SUM\u{c9}", &["r\u{e9}sum\u{e9}"]),
        ("#R\u{e9}sum\u{e9} #r\u{e9}sum\u{e9}", &["r\u{e9}sum\u{e9}"]),
        (
            "#\u{420}\u{430}\u{431}\u{43e}\u{442}\u{430}",
            &["\u{440}\u{430}\u{431}\u{43e}\u{442}\u{430}"],
        ),
    ]);
    // One entry per name across lines, the first line kept.
    let got = extract("Plan #Work today\nmore #work\n#WORK again\n");
    assert_eq!(got, vec![tag("work", "Plan #Work today")]);
}

#[test]
fn extract_returns_one_entry_per_name_sorted_by_name() {
    assert_names(&[
        ("#zeta #alpha #mid", &["alpha", "mid", "zeta"]),
        ("#b\n#a\n#c\n#a", &["a", "b", "c"]),
        ("#ab #a #a-b", &["a", "a-b", "ab"]),
    ]);
    let got = extract("one #zeta\ntwo #alpha #zeta\n");
    assert_eq!(
        got,
        vec![tag("alpha", "two #alpha #zeta"), tag("zeta", "one #zeta")]
    );
}

// ---------- AC 5: combining marks ----------

#[test]
fn decomposed_e_with_combining_mark_stays_in_the_name() {
    assert_names(&[
        // é typed as e + U+0301 is one name, not `re` then text.
        ("#re\u{301}sume\u{301}", &["re\u{301}sume\u{301}"]),
        ("#e\u{301}", &["e\u{301}"]),
        ("#E\u{301}T\u{c9}", &["e\u{301}t\u{e9}"]),
        // Composed and decomposed are two names (no Unicode normalization).
        (
            "#r\u{e9}sum\u{e9} #re\u{301}sume\u{301}",
            &["re\u{301}sume\u{301}", "r\u{e9}sum\u{e9}"],
        ),
        (
            "#q3-plan #r\u{e9}sum\u{e9}",
            &["q3-plan", "r\u{e9}sum\u{e9}"],
        ),
    ]);
}

// ---------- AC 6: slash, brackets, accepted false positives ----------

#[test]
fn slash_and_closing_punctuation_end_a_tag_and_fff_is_a_tag() {
    assert_names(&[
        ("#work/pricing", &["work"]),
        ("#work/#pricing", &["work"]),
        ("see (#memex)", &["memex"]),
        ("see [#memex], {#memex}", &["memex"]),
        ("#fff", &["fff"]),
        ("color: #fff;", &["fff"]),
    ]);
}

// ---------- AC 7: excluded contexts ----------

#[test]
fn no_tag_inside_code_fences_urls_wikilinks_transclusions_or_markdown_links() {
    assert_names(&[
        // Code spans, including double backticks.
        ("`#code`", &[]),
        ("run ` #code` now #after", &["after"]),
        ("``a #b``", &[]),
        ("``a ` #b`` #c", &["c"]),
        ("`x` #y", &["y"]),
        // Fenced code, ``` and ~~~; an unclosed fence runs to the end.
        ("```\n#x\n```\n#y", &["y"]),
        ("```rust\n#x\n```\n#y", &["y"]),
        ("~~~\n#x\n~~~\n#y", &["y"]),
        ("#a\n```\n#x\n```", &["a"]),
        ("```\n#x\n#y", &[]),
        ("~~~\n#x\n\n#y", &[]),
        ("~~~\n#x\n```\n#y", &[]),
        // URLs.
        ("https://example.com/#section", &[]),
        (
            "https://en.wikipedia.org/wiki/Tag_(#metadata) #real",
            &["real"],
        ),
        ("see http://example.com/'#x' and #y", &["y"]),
        // Wikilinks.
        ("[[#x]]", &[]),
        ("[[Note|see #x]] #y", &["y"]),
        ("[[Note~references|(#x)]]", &[]),
        // Transclusion tokens.
        ("![[2026-11-06#^abc12]] #y", &["y"]),
        ("![[2026-11-06#^a1..^b2]]", &[]),
        // Markdown link text and targets.
        ("[#x](https://example.com)", &[]),
        ("[see #x](https://example.com)", &[]),
        ("[see](#x)", &[]),
        ("![#alt](image.png)", &[]),
        ("[a](b) #c", &["c"]),
    ]);
}

#[test]
fn code_span_hides_only_its_own_text() {
    assert_names(&[
        ("` #a` #b ` #c`", &["b"]),
        ("``x`` #y ``#z``", &["y"]),
        ("line one `#a`\n#b", &["b"]),
    ]);
}

#[test]
fn fenced_code_hides_lines_until_its_closing_fence() {
    assert_names(&[
        ("  ```\n#x\n  ```\n#y", &["y"]),
        ("```\n#x\n```\n#y\n```\n#z\n```\n#w", &["w", "y"]),
        ("~~~python\n# comment #x\n~~~\n#y", &["y"]),
        // A tilde line does not close a backtick fence either.
        ("```\n#x\n~~~\n#y", &[]),
        ("before #a\n~~~\n#x", &["a"]),
    ]);
}

#[test]
fn links_and_wikilinks_hide_only_their_own_text() {
    assert_names(&[
        ("[[Note]] #a [[Other|(#b)]] #c", &["a", "c"]),
        ("[x](#a) #b [y](#c)", &["b"]),
        ("https://a.com/(#x) #y https://b.com/(#z)", &["y"]),
        ("[[Note]]\n#next", &["next"]),
    ]);
}

// ---------- AC 8: headings ----------

#[test]
fn heading_hash_is_not_a_tag_but_heading_text_may_hold_tags() {
    assert_names(&[
        ("# Heading", &[]),
        ("# Heading #x", &["x"]),
        ("## Section #y", &["y"]),
        ("###### Deep #z", &["z"]),
        ("intro\n# Heading #x\nbody", &["x"]),
        ("##x", &[]),
        ("###x", &[]),
        ("#", &[]),
        ("# ", &[]),
        ("#Heading", &["heading"]),
    ]);
}

// ---------- AC 9: first_line ----------

#[test]
fn first_line_is_the_trimmed_line_without_list_task_or_quote_marker() {
    let text = "- [ ] call Sam #a\n\
                - [x] done thing #b\n\
                * star item #c\n\
                + plus item #d\n\
                1. first step #e\n\
                12. twelfth step #f\n\
                > quoted idea #g\n\
                \x20  padded line #h   \n\
                \tplain #i\r\n\
                * [ ] star task #j\n\
                - #k\n";
    assert_eq!(
        extract(text),
        vec![
            tag("a", "call Sam #a"),
            tag("b", "done thing #b"),
            tag("c", "star item #c"),
            tag("d", "plus item #d"),
            tag("e", "first step #e"),
            tag("f", "twelfth step #f"),
            tag("g", "quoted idea #g"),
            tag("h", "padded line #h"),
            tag("i", "plain #i"),
            tag("j", "star task #j"),
            tag("k", "#k"),
        ]
    );
    let line = String::from("- [ ] call Sam #work");
    assert_eq!(extract(&line), vec![tag("work", "call Sam #work")]);
}

#[test]
fn first_line_is_the_first_line_that_holds_the_tag() {
    // Earlier lines without the tag, or with it only in excluded text, are skipped.
    let text = "intro\n`#x` in code\n```\n#x fenced\n```\n[[#x]] link\nreal #x here\nlater #x\n";
    assert_eq!(extract(text), vec![tag("x", "real #x here")]);
    // Each tag keeps its own first line; the matching is by lowercase name.
    let text = "a #One\nb #two #ONE\nc #Two\n";
    assert_eq!(
        extract(text),
        vec![tag("one", "a #One"), tag("two", "b #two #ONE")]
    );
    // Text with no tags gives nothing.
    assert_eq!(
        extract("no tags here\n# Heading\n"),
        Vec::<ExtractedTag>::new()
    );
}

// ---------- AC 10: person_section ----------

#[test]
fn person_section_stops_at_first_marker_outside_fenced_code_and_drops_frontmatter() {
    let m = TOPICS_MARKER;

    // No marker: the whole body.
    let body = "a #x\nb\n";
    assert_eq!(person_section(body), body);

    // Stops at the first marker line.
    let body = format!("a #x\n{m}\n[[T~about]]\n{m}\nmore\n");
    assert_eq!(person_section(&body), "a #x\n");

    // A fenced marker is body text, and a later marker still stops it.
    let body = format!("a\n```\n{m}\n```\nb #y\n{m}\n[[T~about]]\n");
    assert_eq!(person_section(&body), format!("a\n```\n{m}\n```\nb #y\n"));
    let body = format!("a\n~~~\n{m}\n~~~\nb\n{m}\nfoot\n");
    assert_eq!(person_section(&body), format!("a\n~~~\n{m}\n~~~\nb\n"));

    // A marker in an unclosed fence is body text to the end.
    let body = format!("a\n```\n{m}\nb\n");
    assert_eq!(person_section(&body), body);

    // A leading frontmatter block is left out; YAML comments never reach extract.
    let body = "---\ntitle: T\ntags: [old]\n# yaml comment #c\n---\nbody #b\n";
    assert_eq!(person_section(body), "body #b\n");
    assert_eq!(names(person_section(body)), vec!["b"]);

    // Frontmatter and a marker together.
    let body = format!("---\nrole: topic\n---\nbody #b\n{m}\n[[T~about]]\n");
    assert_eq!(person_section(&body), "body #b\n");
}

#[test]
fn person_section_matches_marker_lines_like_split_body() {
    let m = TOPICS_MARKER;
    // Trailing spaces and \r on the marker line still match.
    let body = format!("a\n{m}  \r\nfoot\n");
    assert_eq!(person_section(&body), "a\n");
    let body = format!("a\r\n{m}\r\n[[T~about]]\r\n");
    assert_eq!(person_section(&body), "a\r\n");
    // The marker inside a line, or with text after it, is not a marker line.
    let body = format!("see {m} here\nb\n");
    assert_eq!(person_section(&body), body);
    let body = format!("{m} trailing\nb\n");
    assert_eq!(person_section(&body), body);
    // A marker on the first line leaves an empty person section.
    let body = format!("{m}\n[[T~about]]\n");
    assert_eq!(person_section(&body), "");
    // The same person text split_body finds, for a body without stray text.
    for body in [
        format!("p1\np2 #x\n{m}\n[[A~about]]\n[[B~about]]\n"),
        format!("only\n{m}\n"),
        "no marker at all\n".to_string(),
    ] {
        assert_eq!(person_section(&body), split_body(&body).person);
    }
}

#[test]
fn person_section_keeps_a_body_without_closed_frontmatter() {
    // `---` with no closing line is not frontmatter: the whole body is person text.
    let body = "---\n#x\nbody\n";
    assert_eq!(person_section(body), body);
    // `---` not at byte 0 is not frontmatter either.
    let body = "intro\n---\ntitle: T\n---\nrest\n";
    assert_eq!(person_section(body), body);
    // Empty body.
    assert_eq!(person_section(""), "");
}

// ---------- AC 11: normalize_name ----------

#[test]
fn normalize_name_accepts_only_one_whole_valid_name() {
    assert_eq!(normalize_name("Work").as_deref(), Some("work"));
    assert_eq!(normalize_name("work").as_deref(), Some("work"));
    assert_eq!(
        normalize_name("r\u{e9}sum\u{e9}").as_deref(),
        Some("r\u{e9}sum\u{e9}")
    );
    assert_eq!(
        normalize_name("R\u{c9}SUM\u{c9}").as_deref(),
        Some("r\u{e9}sum\u{e9}")
    );
    let owned = format!("{}-{}", "Q3", "Plan");
    assert_eq!(normalize_name(&owned).as_deref(), Some("q3-plan"));

    for bad in [
        "#work", "a b", "1a", "plan-", "", "a_", " work", "work ", "work\n", "a/b", "-a", "_a",
        "\u{301}a", "123", "work.", "##work",
    ] {
        assert_eq!(normalize_name(bad), None, "{bad:?} is not one valid name");
    }

    // The fixture's name table (shared with the Dart port).
    let g = grammar();
    let rows = g["names"]
        .as_array()
        .expect("grammar.json has a names array");
    assert!(rows.len() >= 10);
    let mut failures = Vec::new();
    for r in rows {
        let input = r["input"].as_str().expect("names row has an input");
        let expected = r["name"].as_str().map(str::to_string);
        let got = normalize_name(input);
        if got != expected {
            failures.push(format!("{input:?}: expected {expected:?}, got {got:?}"));
        }
    }
    assert!(
        failures.is_empty(),
        "names rows failed:\n{}",
        failures.join("\n")
    );
}

#[test]
fn normalize_name_agrees_with_extract() {
    // A name extract finds normalizes to itself.
    for text in [
        "#work",
        "#q3-plan",
        "#R\u{c9}SUM\u{c9}",
        "#re\u{301}sume\u{301}",
        "#a_b",
    ] {
        let found = names(text);
        assert_eq!(found.len(), 1, "{text:?} holds one tag");
        assert_eq!(
            normalize_name(&found[0]).as_deref(),
            Some(found[0].as_str())
        );
        assert_eq!(
            normalize_name(&text[1..]).as_deref(),
            Some(found[0].as_str())
        );
    }
}

// ---------- AC 12: is_system_tag ----------

#[test]
fn is_system_tag_is_true_only_for_the_fixture_system_tags() {
    let system = fixture_system_tags();
    assert_eq!(system, vec!["inbox", "agent-authored"]);
    for name in &system {
        assert!(is_system_tag(name), "{name} is a system tag");
    }
    let built = format!("{}-{}", "agent", "authored");
    assert!(is_system_tag(&built));
    for name in [
        "work",
        "",
        "inbox ",
        " inbox",
        "#inbox",
        "inboxes",
        "xinbox",
        "agent",
        "authored",
        "agent_authored",
        "agent-authored-x",
        "agentauthored",
    ] {
        assert!(!is_system_tag(name), "{name:?} is not a system tag");
    }
}

// ---------- verify round: contracts the handoff lists as unpinned ----------

#[test]
fn fence_markers_need_three_matching_characters_and_a_bare_closing_line() {
    assert_names(&[
        // Two backticks or tildes are not a fence.
        ("``\n#x", &["x"]),
        ("~~\n#x", &["x"]),
        // A tab-indented fence still opens.
        ("\t```\n#x\n\t```\n#y", &["y"]),
        // A closing fence is at least as long as the opener.
        ("````\n#x\n```\n#y", &[]),
        ("```\n#x\n````\n#y", &["y"]),
        ("~~~~\n#x\n~~~\n#y", &[]),
        ("~~~\n#x\n~~~~\n#y", &["y"]),
        // A closing fence holds nothing but whitespace after the run.
        ("```\n#x\n```rust\n#y", &[]),
        ("```\n#x\n``` \n#y", &["y"]),
        ("~~~\n#x\n~~~ text\n#y", &[]),
        // A backtick fence info string holds no backtick: that line is a code span.
        ("```code``` #x", &["x"]),
        ("```code``` #x\n#y", &["x", "y"]),
        // A tilde fence info string may hold one.
        ("~~~ a`b\n#x\n~~~\n#y", &["y"]),
        // The opening fence line is code, its info string included.
        ("``` #x\n#y\n```", &[]),
        ("~~~ #x\n~~~\n#y", &["y"]),
    ]);
}

#[test]
fn unpaired_backtick_runs_are_plain_text() {
    assert_names(&[
        ("`a #x", &["x"]),
        ("``a` #x", &["x"]),
        // Equal-length runs pair across an unequal one.
        ("`a`` #x ``b", &[]),
        ("`` ` #x", &["x"]),
        // A later run can still pair after an unpaired one (the single runs pair).
        ("``a` #x `b` #y", &["y"]),
    ]);
}

#[test]
fn first_line_strips_a_quote_then_a_list_marker_and_only_a_real_task_box() {
    let text = "> - item #a\n\
                > - [ ] quoted task #b\n\
                - [X] big box #c\n\
                - [x](https://example.com) linked #d\n\
                - [] empty #e\n\
                -  [ ]  spaced #f\n\
                >tight quote #g\n\
                1.5 not a list #h\n";
    assert_eq!(
        extract(text),
        vec![
            tag("a", "item #a"),
            tag("b", "quoted task #b"),
            tag("c", "big box #c"),
            tag("d", "[x](https://example.com) linked #d"),
            tag("e", "[] empty #e"),
            tag("f", "spaced #f"),
            tag("g", "tight quote #g"),
            tag("h", "1.5 not a list #h"),
        ]
    );
}
