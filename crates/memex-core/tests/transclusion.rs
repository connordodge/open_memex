//! WI #9 (R6): block transclusion — parse, render and the `from-day` /
//! `about` link kinds.
//!
//! - D13: one parser (`link_extractor::parse_transclusions`) and one renderer
//!   (`transclusion::render`), pinned by the CONTRACTS C4 fixtures P1–P5 and
//!   X1–X5, copied verbatim. Rust offsets are UTF-8 bytes (D25).
//! - The extractor emits exactly one `from-day` link per token at the `!`
//!   offset and never a plain wikilink for the `[[…]]` inside it.
//! - `from-day` resolves only to the `role: daily` note titled with the date.
//! - `from-day` and `about` are built-in kinds that only the server writes:
//!   no section heading or frontmatter key creates them.
//!
//! Real SQLite, real schema V5, temp vaults only.

use memex_core::graph;
use memex_core::indexer;
use memex_core::link_extractor::{extract, parse_transclusions, TransclusionToken};
use memex_core::links::{self, Link, LinkKind, LinkSource, PendingLink};
use memex_core::notes::{
    create_note_as, delete_note, get_note, update_note_as, CreateNote, Note, NoteId, RenameOptions,
    UpdateNote,
};
use memex_core::transclusion::{self, RenderedExcerpt};
use memex_core::{Caller, Vault};
use rusqlite::params;
use serde_json::{json, Value};
use tempfile::TempDir;

// ---------------------------------------------------------------------------
// C4 fixtures (verbatim)
// ---------------------------------------------------------------------------

const P1: &str = "See ![[2026-09-05#^b7k2m9]] here";
const P2: &str = "![[2026-09-05#^b7k2m9..^c3d4e5]]";
const P3: &str = "[[2026-09-05#^b7k2m9]]";
const P4: &str = "![[2026-9-5#^b7k2m9]]";
const P5: &str = "café ![[2026-09-05#^b7k2m9]]";

const DAY: &str = "2026-09-05";
/// The C4 render-fixture daily note: blocks (0, b7k2m9), (1, c3d4e5), (2, f6g7h8).
const DAY_BODY: &str = "Fixed the jump arc.\n\n- tried coyote time\n\nSleep was bad.\n";
const FIXTURE_BLOCKS: [(i64, &str, &str); 3] = [
    (0, "b7k2m9", "Fixed the jump arc."),
    (1, "c3d4e5", "- tried coyote time"),
    (2, "f6g7h8", "Sleep was bad."),
];

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn fresh_vault() -> (TempDir, Vault) {
    let dir = tempfile::tempdir().unwrap();
    let vault = Vault::create(dir.path()).unwrap();
    (dir, vault)
}

fn create(vault: &mut Vault, title: &str, body: &str, fm: Option<Value>) -> Note {
    let note = create_note_as(
        vault,
        CreateNote {
            title: Some(title.into()),
            content_md: body.into(),
            frontmatter: fm,
        },
        Caller::Person,
    )
    .unwrap_or_else(|e| panic!("create {title}: {e}"));
    reindex(vault, &note);
    note
}

fn create_daily(vault: &mut Vault, date: &str, body: &str) -> Note {
    create(vault, date, body, Some(json!({ "role": "daily" })))
}

/// A topic note saved and indexed the way the CLI / MCP save paths do it.
fn create_topic(vault: &mut Vault, title: &str, body: &str) -> Note {
    create(vault, title, body, Some(json!({ "role": "topic" })))
}

/// Person update of the body, then reindex from the saved note (D8).
fn set_body(vault: &mut Vault, id: &NoteId, body: &str) -> Note {
    let version = get_note(vault, id).unwrap().version;
    let saved = update_note_as(
        vault,
        id,
        version,
        UpdateNote {
            content_md: Some(body.into()),
            ..Default::default()
        },
        RenameOptions::default(),
        Caller::Person,
    )
    .unwrap_or_else(|e| panic!("update {id}: {e}"));
    reindex(vault, &saved);
    saved
}

fn reindex(vault: &mut Vault, note: &Note) {
    indexer::reindex_note(
        vault.connection_mut(),
        note.id.as_str(),
        &note.content_md,
        None,
    )
    .unwrap();
}

/// `(ord, block_id, text)` of a note's stored blocks, in ord order.
fn blocks_of(vault: &Vault, id: &NoteId) -> Vec<(i64, String, String)> {
    let conn = vault.connection_ref();
    let mut stmt = conn
        .prepare("SELECT ord, block_id, text FROM blocks WHERE note_id = ? ORDER BY ord")
        .unwrap();
    stmt.query_map([id.as_str()], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)))
        .unwrap()
        .collect::<Result<_, _>>()
        .unwrap()
}

/// Pins the stored block ids of `note` to the C4 fixture ids by ord.
fn pin_fixture_ids(vault: &Vault, note: &Note) {
    let texts: Vec<String> = blocks_of(vault, &note.id)
        .into_iter()
        .map(|(_, _, t)| t)
        .collect();
    let expected: Vec<&str> = FIXTURE_BLOCKS.iter().map(|(_, _, t)| *t).collect();
    assert_eq!(
        texts, expected,
        "precondition: the day splits into the C4 blocks"
    );
    for (ord, id, _) in FIXTURE_BLOCKS {
        let n = vault
            .connection_ref()
            .execute(
                "UPDATE blocks SET block_id = ? WHERE note_id = ? AND ord = ?",
                params![id, note.id.as_str(), ord],
            )
            .unwrap();
        assert_eq!(n, 1, "block at ord {ord}");
    }
}

/// The C4 render-fixture daily note `2026-09-05` with the literal block ids.
fn fixture_day(vault: &mut Vault) -> Note {
    let note = create_daily(vault, DAY, DAY_BODY);
    pin_fixture_ids(vault, &note);
    note
}

fn tok(date: &str, from: &str, to: Option<&str>) -> TransclusionToken {
    let text = match to {
        Some(to) => format!("![[{date}#^{from}..^{to}]]"),
        None => format!("![[{date}#^{from}]]"),
    };
    TransclusionToken {
        date: date.into(),
        from: from.into(),
        to: to.map(Into::into),
        start: 0,
        end: text.len(),
    }
}

fn render(vault: &Vault, token: &TransclusionToken) -> RenderedExcerpt {
    transclusion::render(vault.connection_ref(), token)
        .unwrap_or_else(|e| panic!("render {token:?}: {e}"))
}

fn links_out(vault: &Vault, id: &NoteId) -> Vec<Link> {
    links::links_out_for_note(vault, id.as_str()).unwrap()
}

fn sorted_by_position(links: &[PendingLink]) -> Vec<&PendingLink> {
    let mut out: Vec<&PendingLink> = links.iter().collect();
    out.sort_by_key(|l| l.position);
    out
}

fn summary(l: &PendingLink) -> (&str, &str, i64, LinkSource) {
    (
        l.link_kind.as_str(),
        l.link_text.as_str(),
        l.position,
        l.source,
    )
}

// ---------------------------------------------------------------------------
// AC 1: parse_transclusions passes C4 P1–P5 (UTF-8 byte offsets)
// ---------------------------------------------------------------------------

#[test]
fn parse_p1_single_block_token_with_byte_offsets() {
    assert_eq!(
        parse_transclusions(P1),
        vec![TransclusionToken {
            date: "2026-09-05".into(),
            from: "b7k2m9".into(),
            to: None,
            start: 4,
            end: 27,
        }]
    );
}

#[test]
fn parse_p2_range_token_with_byte_offsets() {
    assert_eq!(
        parse_transclusions(P2),
        vec![TransclusionToken {
            date: "2026-09-05".into(),
            from: "b7k2m9".into(),
            to: Some("c3d4e5".into()),
            start: 0,
            end: 32,
        }]
    );
}

#[test]
fn parse_p3_plain_wikilink_without_bang_is_not_a_token() {
    assert_eq!(parse_transclusions(P3), vec![]);
}

#[test]
fn parse_p4_non_iso_date_is_not_a_token() {
    assert_eq!(parse_transclusions(P4), vec![]);
}

#[test]
fn parse_p5_offsets_are_utf8_bytes_after_multibyte_text() {
    let tokens = parse_transclusions(P5);
    assert_eq!(
        tokens,
        vec![TransclusionToken {
            date: "2026-09-05".into(),
            from: "b7k2m9".into(),
            to: None,
            start: 6,
            end: 29,
        }]
    );
    assert_eq!(
        &P5[tokens[0].start..tokens[0].end],
        "![[2026-09-05#^b7k2m9]]"
    );
}

#[test]
fn parse_returns_every_token_in_order_with_exact_spans() {
    let text = "a ![[2026-09-05#^b7k2m9]]\n\nb ![[2026-09-04#^aa..^bb]]![[2026-09-03#^cc]]";
    let tokens = parse_transclusions(text);
    let spans: Vec<(&str, &str, Option<&str>, &str)> = tokens
        .iter()
        .map(|t| {
            (
                t.date.as_str(),
                t.from.as_str(),
                t.to.as_deref(),
                &text[t.start..t.end],
            )
        })
        .collect();
    assert_eq!(
        spans,
        vec![
            ("2026-09-05", "b7k2m9", None, "![[2026-09-05#^b7k2m9]]"),
            ("2026-09-04", "aa", Some("bb"), "![[2026-09-04#^aa..^bb]]"),
            ("2026-09-03", "cc", None, "![[2026-09-03#^cc]]"),
        ]
    );
}

#[test]
fn parse_block_id_length_and_alphabet_follow_the_c4_regex() {
    let max = "a".repeat(26);
    let too_long = "a".repeat(27);
    let ok = format!("![[2026-09-05#^{max}]]");
    assert_eq!(parse_transclusions(&ok).len(), 1, "26-char id is a token");
    assert_eq!(parse_transclusions(&ok)[0].from, max);
    let long = format!("![[2026-09-05#^{too_long}]]");
    assert_eq!(
        parse_transclusions(&long),
        vec![],
        "27-char id is not a token"
    );
    assert_eq!(parse_transclusions("![[2026-09-05#^B7K2]]"), vec![]);
    assert_eq!(parse_transclusions("![[2026-09-05#^]]"), vec![]);
    assert_eq!(parse_transclusions("![[2026-09-05#b7k2]]"), vec![]);
    assert_eq!(parse_transclusions(""), vec![]);
}

// ---------------------------------------------------------------------------
// AC 2: one from-day link at the `!` offset, no references link
// ---------------------------------------------------------------------------

#[test]
fn extract_p1_yields_exactly_one_from_day_link_at_the_bang_offset() {
    let r = extract(P1);
    assert!(r.frontmatter.is_empty());
    assert_eq!(r.body.len(), 1, "exactly one body link: {:?}", r.body);
    let link = &r.body[0];
    assert_eq!(link.link_kind.as_str(), "from-day");
    assert_eq!(link.link_text, "2026-09-05");
    assert_eq!(link.position, 4);
    assert_eq!(link.source, LinkSource::InlineBody);
    assert_eq!(link.label, None);
    assert!(
        r.body.iter().all(|l| l.link_kind.as_str() != "references"),
        "no references link for the token"
    );
}

#[test]
fn extract_from_day_position_counts_frontmatter_bytes() {
    let md = "---\ntags: []\n---\nSee ![[2026-09-05#^b7k2m9]] here";
    let r = extract(md);
    assert_eq!(r.body.len(), 1, "{:?}", r.body);
    let bang = md.find('!').unwrap() as i64;
    assert_eq!(
        summary(&r.body[0]),
        ("from-day", "2026-09-05", bang, LinkSource::InlineBody)
    );
}

#[test]
fn extract_from_day_position_is_a_utf8_byte_offset() {
    let r = extract(P5);
    assert_eq!(r.body.len(), 1, "{:?}", r.body);
    assert_eq!(
        summary(&r.body[0]),
        ("from-day", "2026-09-05", 6, LinkSource::InlineBody)
    );
}

#[test]
fn extract_emits_one_from_day_link_per_token() {
    let md = "![[2026-09-05#^b7k2m9]]\n\n![[2026-09-04#^c3d4e5..^f6g7h8]]";
    let r = extract(md);
    let got: Vec<_> = sorted_by_position(&r.body)
        .into_iter()
        .map(summary)
        .collect();
    assert_eq!(
        got,
        vec![
            ("from-day", "2026-09-05", 0, LinkSource::InlineBody),
            ("from-day", "2026-09-04", 25, LinkSource::InlineBody),
        ]
    );
}

#[test]
fn extract_leaves_non_transclusion_wikilinks_unchanged() {
    // P3 has no `!` and P4 is not an ISO date: neither is a transclusion, so
    // both keep today's plain-wikilink output.
    let r3 = extract(P3);
    assert_eq!(r3.body.len(), 1);
    assert_eq!(
        summary(&r3.body[0]),
        (
            "references",
            "2026-09-05#^b7k2m9",
            0,
            LinkSource::InlineBody
        )
    );
    let r4 = extract(P4);
    assert_eq!(r4.body.len(), 1);
    assert_eq!(
        summary(&r4.body[0]),
        ("references", "2026-9-5#^b7k2m9", 1, LinkSource::InlineBody)
    );
}

// ---------------------------------------------------------------------------
// AC 3: token + plain wikilink → exactly two links
// ---------------------------------------------------------------------------

#[test]
fn extract_range_token_and_wikilink_yield_exactly_two_links() {
    let md = "![[2026-09-05#^b7k2m9..^c3d4e5]]\n\nSee also [[Player Loop]].";
    let r = extract(md);
    assert!(r.frontmatter.is_empty());
    let wikilink_at = md.find("[[Player Loop]]").unwrap() as i64;
    let got: Vec<_> = sorted_by_position(&r.body)
        .into_iter()
        .map(summary)
        .collect();
    assert_eq!(
        got,
        vec![
            ("from-day", "2026-09-05", 0, LinkSource::InlineBody),
            (
                "references",
                "Player Loop",
                wikilink_at,
                LinkSource::InlineBody
            ),
        ]
    );
}

#[test]
fn extract_wikilink_directly_after_a_token_keeps_its_offset() {
    let md = "![[2026-09-05#^b7k2m9]][[Player Loop]]";
    let r = extract(md);
    let got: Vec<_> = sorted_by_position(&r.body)
        .into_iter()
        .map(summary)
        .collect();
    assert_eq!(
        got,
        vec![
            ("from-day", "2026-09-05", 0, LinkSource::InlineBody),
            ("references", "Player Loop", 23, LinkSource::InlineBody),
        ]
    );
}

#[test]
fn extract_wikilink_directly_before_a_token_keeps_its_offset() {
    let md = "[[Player Loop]]![[2026-09-05#^b7k2m9..^c3d4e5]]";
    let r = extract(md);
    let got: Vec<_> = sorted_by_position(&r.body)
        .into_iter()
        .map(summary)
        .collect();
    assert_eq!(
        got,
        vec![
            ("references", "Player Loop", 0, LinkSource::InlineBody),
            ("from-day", "2026-09-05", 15, LinkSource::InlineBody),
        ]
    );
}

#[test]
fn extract_wikilink_after_a_token_and_multibyte_text_keeps_its_byte_offset() {
    let md = "café ![[2026-09-05#^b7k2m9]] — [[Player Loop~extends]]";
    let r = extract(md);
    let wikilink_at = md.find("[[Player Loop").unwrap() as i64;
    let got: Vec<_> = sorted_by_position(&r.body)
        .into_iter()
        .map(summary)
        .collect();
    assert_eq!(
        got,
        vec![
            ("from-day", "2026-09-05", 6, LinkSource::InlineBody),
            (
                "extends",
                "Player Loop",
                wikilink_at,
                LinkSource::InlineBody
            ),
        ]
    );
}

// ---------------------------------------------------------------------------
// AC 4: a section heading does not change the kind of a token
// ---------------------------------------------------------------------------

#[test]
fn extract_token_under_contradicts_heading_stays_from_day() {
    let md = "## Contradicts\n\n![[2026-09-05#^b7k2m9]]\n[[Foo]]\n";
    let r = extract(md);
    let bang = md.find('!').unwrap() as i64;
    let foo = md.find("[[Foo]]").unwrap() as i64;
    let got: Vec<_> = sorted_by_position(&r.body)
        .into_iter()
        .map(summary)
        .collect();
    assert_eq!(
        got,
        vec![
            ("from-day", "2026-09-05", bang, LinkSource::InlineBody),
            ("contradicts", "Foo", foo, LinkSource::InlineSection),
        ]
    );
}

// ---------------------------------------------------------------------------
// AC 5: from-day resolves only to the role: daily note titled with the date
// ---------------------------------------------------------------------------

#[test]
fn saved_topic_from_day_link_targets_the_daily_note() {
    let (_d, mut vault) = fresh_vault();
    let day = create_daily(&mut vault, DAY, DAY_BODY);
    let topic = create_topic(
        &mut vault,
        "Player Loop",
        "## 2026-09-05\n\n![[2026-09-05#^b7k2m9]]\n",
    );
    let out = links_out(&vault, &topic.id);
    assert_eq!(out.len(), 1, "{out:?}");
    assert_eq!(out[0].link_kind.as_str(), "from-day");
    assert_eq!(out[0].link_text, DAY);
    assert_eq!(out[0].to_note_id.as_deref(), Some(day.id.as_str()));
    assert_eq!(out[0].source, LinkSource::InlineBody);
}

#[test]
fn from_day_link_to_a_role_less_note_with_the_date_title_is_null() {
    let (_d, mut vault) = fresh_vault();
    let _roleless = create(&mut vault, DAY, "not a daily note", None);
    let topic = create_topic(&mut vault, "Player Loop", "![[2026-09-05#^b7k2m9]]\n");
    let out = links_out(&vault, &topic.id);
    assert_eq!(out.len(), 1, "{out:?}");
    assert_eq!(out[0].link_kind.as_str(), "from-day");
    assert_eq!(out[0].to_note_id, None);
}

#[test]
fn from_day_link_to_a_topic_note_with_the_date_title_is_null() {
    let (_d, mut vault) = fresh_vault();
    let _other = create(&mut vault, DAY, "a topic", Some(json!({ "role": "topic" })));
    let topic = create_topic(&mut vault, "Player Loop", "![[2026-09-05#^b7k2m9]]\n");
    let out = links_out(&vault, &topic.id);
    assert_eq!(out.len(), 1, "{out:?}");
    assert_eq!(out[0].link_kind.as_str(), "from-day");
    assert_eq!(out[0].link_text, DAY);
    assert_eq!(out[0].to_note_id, None);
}

#[test]
fn from_day_resolution_tolerates_invalid_frontmatter_json() {
    let (_d, mut vault) = fresh_vault();
    let other = create(&mut vault, DAY, "broken", None);
    vault
        .connection_ref()
        .execute(
            "UPDATE notes SET frontmatter = 'not json {' WHERE id = ?",
            [other.id.as_str()],
        )
        .unwrap();
    let topic = create_topic(&mut vault, "Player Loop", "![[2026-09-05#^b7k2m9]]\n");
    let out = links_out(&vault, &topic.id);
    assert_eq!(out.len(), 1, "{out:?}");
    assert_eq!(out[0].link_kind.as_str(), "from-day");
    assert_eq!(out[0].to_note_id, None);
}

#[test]
fn from_day_link_with_no_note_for_the_date_is_null() {
    let (_d, mut vault) = fresh_vault();
    let _day = create_daily(&mut vault, DAY, DAY_BODY);
    let topic = create_topic(&mut vault, "Player Loop", "![[2026-09-06#^b7k2m9]]\n");
    let out = links_out(&vault, &topic.id);
    assert_eq!(out.len(), 1, "{out:?}");
    assert_eq!(out[0].link_kind.as_str(), "from-day");
    assert_eq!(out[0].link_text, "2026-09-06");
    assert_eq!(out[0].to_note_id, None);
}

#[test]
fn plain_wikilink_to_a_role_less_date_title_still_resolves_by_title() {
    // Other kinds keep resolving by title, role or not.
    let (_d, mut vault) = fresh_vault();
    let roleless = create(&mut vault, DAY, "not a daily note", None);
    let topic = create_topic(
        &mut vault,
        "Player Loop",
        "[[2026-09-05]] and ![[2026-09-05#^b7k2m9]]\n",
    );
    let out = links_out(&vault, &topic.id);
    let by_kind: Vec<(&str, Option<&str>)> = out
        .iter()
        .map(|l| (l.link_kind.as_str(), l.to_note_id.as_deref()))
        .collect();
    assert_eq!(
        by_kind,
        vec![
            ("references", Some(roleless.id.as_str())),
            ("from-day", None),
        ]
    );
}

// ---------------------------------------------------------------------------
// AC 6: from-day and about are built-in kinds
// ---------------------------------------------------------------------------

#[test]
fn from_day_is_a_built_in_link_kind() {
    assert_eq!(LinkKind::FROM_DAY, "from-day");
    let kind = LinkKind::new("from-day").unwrap();
    assert_eq!(kind.as_str(), "from-day");
    assert!(kind.is_built_in());
}

#[test]
fn about_is_a_built_in_link_kind() {
    assert_eq!(LinkKind::ABOUT, "about");
    let kind = LinkKind::new("about").unwrap();
    assert_eq!(kind.as_str(), "about");
    assert!(kind.is_built_in());
}

#[test]
fn user_defined_kinds_stay_non_built_in_next_to_the_new_kinds() {
    for k in ["about-face", "from-days", "inspired-by"] {
        assert!(!LinkKind::new(k).unwrap().is_built_in(), "{k}");
    }
    for k in ["references", "extends", "contradicts", "example-of"] {
        assert!(LinkKind::new(k).unwrap().is_built_in(), "{k}");
    }
}

// ---------------------------------------------------------------------------
// AC 7: about is written only by explicit syntax, never by a shortcut
// ---------------------------------------------------------------------------

#[test]
fn explicit_about_wikilink_yields_kind_about() {
    let r = extract("[[Sleep~about]]");
    assert_eq!(r.body.len(), 1);
    assert_eq!(
        summary(&r.body[0]),
        ("about", "Sleep", 0, LinkSource::InlineBody)
    );
}

#[test]
fn about_heading_does_not_create_about_links() {
    let md = "## About\n\n[[Sleep]]\n";
    let r = extract(md);
    let at = md.find("[[Sleep]]").unwrap() as i64;
    assert_eq!(r.body.len(), 1);
    assert_eq!(
        summary(&r.body[0]),
        ("references", "Sleep", at, LinkSource::InlineBody)
    );
}

#[test]
fn from_day_heading_does_not_create_from_day_links() {
    let md = "## From day\n\n[[Sleep]]\n\n## From-day\n\n[[Rest]]\n";
    let r = extract(md);
    let kinds: Vec<&str> = r.body.iter().map(|l| l.link_kind.as_str()).collect();
    assert_eq!(kinds, vec!["references", "references"]);
}

#[test]
fn frontmatter_about_key_yields_no_link() {
    let r = extract("---\nabout: \"[[Sleep]]\"\n---\nbody\n");
    assert!(!r.frontmatter_parse_error);
    assert!(r.frontmatter.is_empty(), "{:?}", r.frontmatter);
    assert!(r.body.is_empty());
}

#[test]
fn frontmatter_from_day_key_yields_no_link() {
    let r = extract("---\nfrom-day: \"[[Sleep]]\"\n---\nbody\n");
    assert!(!r.frontmatter_parse_error);
    assert!(r.frontmatter.is_empty(), "{:?}", r.frontmatter);
    assert!(r.body.is_empty());
}

#[test]
fn frontmatter_other_keys_still_link_next_to_about_and_from_day() {
    let md = "---\nabout: \"[[Sleep]]\"\nextends: \"[[Rest]]\"\nfrom-day:\n  - \"[[Sleep]]\"\ninspired-by: \"[[Naps]]\"\n---\nbody\n";
    let r = extract(md);
    let mut got: Vec<(&str, &str)> = r
        .frontmatter
        .iter()
        .map(|l| (l.link_kind.as_str(), l.link_text.as_str()))
        .collect();
    got.sort();
    assert_eq!(got, vec![("extends", "Rest"), ("inspired-by", "Naps")]);
}

#[test]
fn saved_about_link_is_stored_with_kind_about() {
    let (_d, mut vault) = fresh_vault();
    let sleep = create_topic(&mut vault, "Sleep", "Topic.");
    let host = create_topic(&mut vault, "Night log", "[[Sleep~about]]\n");
    let out = links_out(&vault, &host.id);
    assert_eq!(out.len(), 1, "{out:?}");
    assert_eq!(out[0].link_kind.as_str(), "about");
    assert_eq!(out[0].to_note_id.as_deref(), Some(sleep.id.as_str()));
    let hits =
        graph::neighbors(vault.connection_ref(), sleep.id.as_str(), 1, Some("about")).unwrap();
    assert_eq!(
        hits.iter().map(|h| h.note_id.as_str()).collect::<Vec<_>>(),
        vec![host.id.as_str()]
    );
}

// ---------------------------------------------------------------------------
// AC 8: transclusion::render passes C4 X1–X5
// ---------------------------------------------------------------------------

#[test]
fn render_x1_single_block() {
    let (_d, mut vault) = fresh_vault();
    fixture_day(&mut vault);
    assert_eq!(
        render(&vault, &tok(DAY, "b7k2m9", None)),
        RenderedExcerpt {
            date: DAY.into(),
            from: "b7k2m9".into(),
            to: None,
            text: "Fixed the jump arc.".into(),
            removed: false,
        }
    );
}

#[test]
fn render_x2_range_joins_blocks_with_newline() {
    let (_d, mut vault) = fresh_vault();
    fixture_day(&mut vault);
    assert_eq!(
        render(&vault, &tok(DAY, "b7k2m9", Some("c3d4e5"))),
        RenderedExcerpt {
            date: DAY.into(),
            from: "b7k2m9".into(),
            to: Some("c3d4e5".into()),
            text: "Fixed the jump arc.\n- tried coyote time".into(),
            removed: false,
        }
    );
}

#[test]
fn render_x3_missing_block_is_the_removed_stub() {
    let (_d, mut vault) = fresh_vault();
    fixture_day(&mut vault);
    assert_eq!(
        render(&vault, &tok(DAY, "zzzzzz", None)),
        RenderedExcerpt {
            date: DAY.into(),
            from: "zzzzzz".into(),
            to: None,
            text: "removed from 2026-09-05".into(),
            removed: true,
        }
    );
}

#[test]
fn render_x4_range_with_a_missing_endpoint_is_the_removed_stub() {
    let (_d, mut vault) = fresh_vault();
    fixture_day(&mut vault);
    assert_eq!(
        render(&vault, &tok(DAY, "b7k2m9", Some("zzzzzz"))),
        RenderedExcerpt {
            date: DAY.into(),
            from: "b7k2m9".into(),
            to: Some("zzzzzz".into()),
            text: "removed from 2026-09-05".into(),
            removed: true,
        }
    );
}

#[test]
fn render_x4_range_with_a_missing_start_is_the_removed_stub() {
    let (_d, mut vault) = fresh_vault();
    fixture_day(&mut vault);
    let r = render(&vault, &tok(DAY, "zzzzzz", Some("c3d4e5")));
    assert_eq!(r.text, "removed from 2026-09-05");
    assert!(r.removed);
}

#[test]
fn render_x5_no_daily_note_for_the_date_is_the_removed_stub() {
    let (_d, mut vault) = fresh_vault();
    fixture_day(&mut vault);
    assert_eq!(
        render(&vault, &tok("2026-09-06", "b7k2m9", None)),
        RenderedExcerpt {
            date: "2026-09-06".into(),
            from: "b7k2m9".into(),
            to: None,
            text: "removed from 2026-09-06".into(),
            removed: true,
        }
    );
}

#[test]
fn render_full_range_includes_every_block_between_the_endpoints() {
    let (_d, mut vault) = fresh_vault();
    fixture_day(&mut vault);
    let r = render(&vault, &tok(DAY, "b7k2m9", Some("f6g7h8")));
    assert_eq!(
        r.text,
        "Fixed the jump arc.\n- tried coyote time\nSleep was bad."
    );
    assert!(!r.removed);
    let tail = render(&vault, &tok(DAY, "c3d4e5", Some("f6g7h8")));
    assert_eq!(tail.text, "- tried coyote time\nSleep was bad.");
    let same = render(&vault, &tok(DAY, "c3d4e5", Some("c3d4e5")));
    assert_eq!(same.text, "- tried coyote time");
}

#[test]
fn render_resolves_blocks_only_within_the_daily_note_for_the_date() {
    // The block id exists, but in another day's note: still removed.
    let (_d, mut vault) = fresh_vault();
    let other = create_daily(&mut vault, "2026-09-04", DAY_BODY);
    pin_fixture_ids(&vault, &other);
    let _day = create_daily(&mut vault, DAY, "Something else entirely.\n");
    let r = render(&vault, &tok(DAY, "b7k2m9", None));
    assert_eq!(r.text, "removed from 2026-09-05");
    assert!(r.removed);
    let found = render(&vault, &tok("2026-09-04", "b7k2m9", None));
    assert_eq!(found.text, "Fixed the jump arc.");
    assert!(!found.removed);
}

#[test]
fn render_ignores_blocks_of_a_role_less_note_with_the_date_title() {
    let (_d, mut vault) = fresh_vault();
    let roleless = create(&mut vault, DAY, "Fixed the jump arc.\n", None);
    vault
        .connection_ref()
        .execute(
            "INSERT INTO blocks (note_id, block_id, ord, start_byte, end_byte, text,
                                 content_hash, source, created_version, created_at)
             VALUES (?, 'b7k2m9', 0, 0, 19, 'Fixed the jump arc.', '0000000000000000',
                     'person', 1, 1)",
            [roleless.id.as_str()],
        )
        .unwrap();
    let r = render(&vault, &tok(DAY, "b7k2m9", None));
    assert_eq!(r.text, "removed from 2026-09-05");
    assert!(r.removed);
}

#[test]
fn render_all_renders_every_token_of_a_host_body_in_order() {
    let (_d, mut vault) = fresh_vault();
    fixture_day(&mut vault);
    let body = "## 2026-09-05\n\n![[2026-09-05#^f6g7h8]]\n\nnotes [[Sleep]]\n\n\
                ![[2026-09-06#^b7k2m9]]\n![[2026-09-05#^b7k2m9..^c3d4e5]]\n";
    let rendered = transclusion::render_all(vault.connection_ref(), body).unwrap();
    assert_eq!(
        rendered,
        vec![
            RenderedExcerpt {
                date: DAY.into(),
                from: "f6g7h8".into(),
                to: None,
                text: "Sleep was bad.".into(),
                removed: false,
            },
            RenderedExcerpt {
                date: "2026-09-06".into(),
                from: "b7k2m9".into(),
                to: None,
                text: "removed from 2026-09-06".into(),
                removed: true,
            },
            RenderedExcerpt {
                date: DAY.into(),
                from: "b7k2m9".into(),
                to: Some("c3d4e5".into()),
                text: "Fixed the jump arc.\n- tried coyote time".into(),
                removed: false,
            },
        ]
    );
}

#[test]
fn render_all_of_a_body_without_tokens_is_empty() {
    let (_d, mut vault) = fresh_vault();
    fixture_day(&mut vault);
    let rendered =
        transclusion::render_all(vault.connection_ref(), "[[2026-09-05#^b7k2m9]] plain").unwrap();
    assert_eq!(rendered, vec![]);
}

#[test]
fn render_all_parses_c4_fixture_tokens_like_render() {
    let (_d, mut vault) = fresh_vault();
    fixture_day(&mut vault);
    let cases = [
        ("![[2026-09-05#^b7k2m9]]", "Fixed the jump arc."),
        (
            "![[2026-09-05#^b7k2m9..^c3d4e5]]",
            "Fixed the jump arc.\n- tried coyote time",
        ),
        ("![[2026-09-05#^zzzzzz]]", "removed from 2026-09-05"),
        (
            "![[2026-09-05#^b7k2m9..^zzzzzz]]",
            "removed from 2026-09-05",
        ),
        ("![[2026-09-06#^b7k2m9]]", "removed from 2026-09-06"),
    ];
    for (token, expected) in cases {
        let rendered = transclusion::render_all(vault.connection_ref(), token).unwrap();
        assert_eq!(rendered.len(), 1, "{token}");
        assert_eq!(rendered[0].text, expected, "{token}");
    }
}

// ---------------------------------------------------------------------------
// AC 9: a reversed range renders like X2
// ---------------------------------------------------------------------------

#[test]
fn render_reversed_range_matches_x2() {
    let (_d, mut vault) = fresh_vault();
    fixture_day(&mut vault);
    let r = render(&vault, &tok(DAY, "c3d4e5", Some("b7k2m9")));
    assert_eq!(r.text, "Fixed the jump arc.\n- tried coyote time");
    assert!(!r.removed);
    assert_eq!(r.from, "c3d4e5");
    assert_eq!(r.to.as_deref(), Some("b7k2m9"));
}

#[test]
fn render_reversed_full_range_keeps_ord_order() {
    let (_d, mut vault) = fresh_vault();
    fixture_day(&mut vault);
    let r = render(&vault, &tok(DAY, "f6g7h8", Some("b7k2m9")));
    assert_eq!(
        r.text,
        "Fixed the jump arc.\n- tried coyote time\nSleep was bad."
    );
}

// ---------------------------------------------------------------------------
// AC 10: Req 12 end to end — a rewritten paragraph renders the removed stub
// ---------------------------------------------------------------------------

#[test]
fn rewritten_paragraph_renders_removed_stub_end_to_end() {
    let (_d, mut vault) = fresh_vault();
    let day = create_daily(&mut vault, DAY, DAY_BODY);
    let before = blocks_of(&vault, &day.id);
    let sleep_id = before[2].1.clone();
    assert_eq!(before[2].2, "Sleep was bad.");

    let body = format!("## {DAY}\n\n![[{DAY}#^{sleep_id}]]\n");
    let topic = create_topic(&mut vault, "Sleep", &body);
    let live = transclusion::render_all(vault.connection_ref(), &topic.content_md).unwrap();
    assert_eq!(live.len(), 1);
    assert_eq!(live[0].text, "Sleep was bad.");
    assert!(!live[0].removed);

    set_body(
        &mut vault,
        &day.id,
        "Fixed the jump arc.\n\n- tried coyote time\n\nBought a mechanical keyboard for the studio.\n",
    );
    let after = blocks_of(&vault, &day.id);
    assert_eq!(after[2].2, "Bought a mechanical keyboard for the studio.");
    assert_ne!(
        after[2].1, sleep_id,
        "precondition: the rewrite minted a new id"
    );

    let gone = transclusion::render_all(vault.connection_ref(), &topic.content_md).unwrap();
    assert_eq!(gone.len(), 1);
    assert_eq!(gone[0].text, "removed from 2026-09-05");
    assert!(gone[0].removed);
}

#[test]
fn lightly_edited_paragraph_renders_its_live_text_end_to_end() {
    let (_d, mut vault) = fresh_vault();
    let day = create_daily(&mut vault, DAY, DAY_BODY);
    let arc_id = blocks_of(&vault, &day.id)[0].1.clone();
    let token = tok(DAY, &arc_id, None);
    assert_eq!(render(&vault, &token).text, "Fixed the jump arc.");

    set_body(
        &mut vault,
        &day.id,
        "Fixed the jump arc again.\n\n- tried coyote time\n\nSleep was bad.\n",
    );
    assert_eq!(
        blocks_of(&vault, &day.id)[0].1,
        arc_id,
        "precondition: a light edit keeps the block id"
    );
    let r = render(&vault, &token);
    assert_eq!(r.text, "Fixed the jump arc again.");
    assert!(!r.removed);
}

// ---------------------------------------------------------------------------
// AC 11: Req 9 end to end — deleting the daily note
// ---------------------------------------------------------------------------

#[test]
fn deleted_daily_note_renders_removed_stub_and_nulls_the_link() {
    let (_d, mut vault) = fresh_vault();
    let day = fixture_day(&mut vault);
    let topic = create_topic(
        &mut vault,
        "Player Loop",
        "## 2026-09-05\n\n![[2026-09-05#^b7k2m9..^c3d4e5]]\n",
    );
    let before = links_out(&vault, &topic.id);
    assert_eq!(before.len(), 1, "{before:?}");
    assert_eq!(before[0].link_kind.as_str(), "from-day");
    assert_eq!(before[0].to_note_id.as_deref(), Some(day.id.as_str()));
    let live = transclusion::render_all(vault.connection_ref(), &topic.content_md).unwrap();
    assert_eq!(live[0].text, "Fixed the jump arc.\n- tried coyote time");

    delete_note(&mut vault, &day.id).unwrap();

    let gone = transclusion::render_all(vault.connection_ref(), &topic.content_md).unwrap();
    assert_eq!(gone.len(), 1);
    assert_eq!(gone[0].text, "removed from 2026-09-05");
    assert!(gone[0].removed);
    let after = links_out(&vault, &topic.id);
    assert_eq!(after.len(), 1, "{after:?}");
    assert_eq!(after[0].link_kind.as_str(), "from-day");
    assert_eq!(after[0].to_note_id, None);

    // Re-saving the topic keeps the link unresolved.
    let topic = set_body(&mut vault, &topic.id, &topic.content_md.clone());
    let resaved = links_out(&vault, &topic.id);
    assert_eq!(resaved.len(), 1);
    assert_eq!(resaved[0].link_kind.as_str(), "from-day");
    assert_eq!(resaved[0].to_note_id, None);
}

// ---------------------------------------------------------------------------
// AC 12: neighbors sees the from-day edge in both directions
// ---------------------------------------------------------------------------

#[test]
fn neighbors_of_topic_include_the_daily_note_via_from_day() {
    let (_d, mut vault) = fresh_vault();
    let day = fixture_day(&mut vault);
    let topic = create_topic(&mut vault, "Player Loop", "![[2026-09-05#^b7k2m9]]\n");
    let hits = graph::neighbors(vault.connection_ref(), topic.id.as_str(), 1, None).unwrap();
    let hit = hits
        .iter()
        .find(|h| h.note_id == day.id.as_str())
        .unwrap_or_else(|| panic!("daily note not a neighbor: {hits:?}"));
    assert_eq!(hit.title, DAY);
    assert_eq!(hit.distance, 1);
    assert!(
        hit.edges.iter().any(|e| e.link_kind == "from-day"
            && e.from_note_id == topic.id.as_str()
            && e.to_note_id == day.id.as_str()),
        "{:?}",
        hit.edges
    );
}

#[test]
fn neighbors_of_daily_note_include_the_transcluding_topic() {
    let (_d, mut vault) = fresh_vault();
    let day = fixture_day(&mut vault);
    let topic = create_topic(&mut vault, "Player Loop", "![[2026-09-05#^b7k2m9]]\n");
    let hits = graph::neighbors(
        vault.connection_ref(),
        day.id.as_str(),
        1,
        Some(LinkKind::FROM_DAY),
    )
    .unwrap();
    assert_eq!(
        hits.iter().map(|h| h.note_id.as_str()).collect::<Vec<_>>(),
        vec![topic.id.as_str()]
    );
    assert_eq!(hits[0].title, "Player Loop");
    assert!(hits[0]
        .edges
        .iter()
        .all(|e| e.link_kind == "from-day" && e.from_note_id == topic.id.as_str()));
}

// ---------------------------------------------------------------------------
// Implementer additions: behavior beyond the ACs
// ---------------------------------------------------------------------------

#[test]
fn parse_date_digits_are_ascii_only_like_dart() {
    // Dart's `\d` is ASCII-only; the Rust twin must agree (D13), so
    // Arabic-Indic digits never form a token.
    let text = "![[\u{662}\u{660}\u{662}\u{666}-\u{660}\u{669}-\u{660}\u{665}#^b7k2m9]]";
    assert_eq!(parse_transclusions(text), vec![]);
    assert!(extract(text)
        .body
        .iter()
        .all(|l| l.link_kind.as_str() != "from-day"));
}

#[test]
fn extract_wikilink_brackets_around_a_token_never_swallow_it() {
    // The masked span cannot sit inside any wikilink match, so the outer
    // `[[ … ]]` is not a link and the token is still one from-day link.
    let md = "[[Foo ![[2026-09-05#^b7k2m9]] bar]]";
    let r = extract(md);
    let got: Vec<_> = r.body.iter().map(summary).collect();
    assert_eq!(
        got,
        vec![("from-day", "2026-09-05", 6, LinkSource::InlineBody)]
    );
}

#[test]
fn extract_body_links_come_back_in_position_order() {
    let md = "[[Player Loop]]![[2026-09-05#^b7k2m9]] then [[Sleep~about]]";
    let r = extract(md);
    let got: Vec<_> = r.body.iter().map(summary).collect();
    assert_eq!(
        got,
        vec![
            ("references", "Player Loop", 0, LinkSource::InlineBody),
            ("from-day", "2026-09-05", 15, LinkSource::InlineBody),
            ("about", "Sleep", 44, LinkSource::InlineBody),
        ]
    );
}

#[test]
fn frontmatter_about_and_from_day_keys_are_skipped_after_normalizing() {
    let md = "---\nAbout: \"[[Sleep]]\"\nfrom day: \"[[Rest]]\"\n---\nbody\n";
    let r = extract(md);
    assert!(!r.frontmatter_parse_error);
    assert!(r.frontmatter.is_empty(), "{:?}", r.frontmatter);
}

// ---------------------------------------------------------------------------
// AC 13: docs/wikilinks.md documents transclusion and the server-written kinds
// ---------------------------------------------------------------------------

#[test]
fn wikilinks_doc_documents_transclusion_syntax_and_server_written_kinds() {
    let path = concat!(env!("CARGO_MANIFEST_DIR"), "/../../docs/wikilinks.md");
    let doc = std::fs::read_to_string(path).unwrap_or_else(|e| panic!("read {path}: {e}"));
    for needle in [
        "`![[2026-09-05#^b7k2m9]]`",
        "`![[2026-09-05#^b7k2m9..^c3d4e5]]`",
        "removed from <date>",
        "`removed from 2026-09-05`",
        "`from-day`",
        "`about`",
        "written only by the server",
    ] {
        assert!(doc.contains(needle), "docs/wikilinks.md lacks {needle:?}");
    }
    assert!(
        !doc.contains("reserved for future block-reference / transclusion"),
        "the caret is no longer reserved for future transclusion"
    );
}
