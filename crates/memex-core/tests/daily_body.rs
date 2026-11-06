//! WI #7 (R4): the pure daily-note helpers in `memex_core::daily`.
//!
//! - `split_body` / `assemble`: the canonical daily body (architect ruling
//!   D10). The S1-S8 and J1-J3 fixtures are CONTRACTS C3, verbatim; the Dart
//!   side (`app/lib/src/editor/segments.dart`, #20) passes the same strings.
//! - `today_with_clock` / `resolve_date`: local-time "today" behind an
//!   injectable `canvas::Clock` (D14). Fixed instants sit at noon UTC so the
//!   local date is the same in any test-machine time zone.
//! - `ReviewState::as_str`: the C2 review labels.

use chrono::{Datelike, Duration, Local, NaiveDate, TimeZone, Utc, Weekday};
use memex_core::canvas::Clock;
use memex_core::daily::{self, DailyBody, ReviewState};
use memex_core::MemexError;

struct FixedClock(i64);

impl Clock for FixedClock {
    fn now_ms(&self) -> i64 {
        self.0
    }
}

fn noon_utc(y: i32, m: u32, d: u32) -> FixedClock {
    FixedClock(
        Utc.with_ymd_and_hms(y, m, d, 12, 0, 0)
            .single()
            .unwrap()
            .timestamp_millis(),
    )
}

fn local_ms(y: i32, m: u32, d: u32, h: u32, min: u32, s: u32) -> i64 {
    Local
        .with_ymd_and_hms(y, m, d, h, min, s)
        .earliest()
        .unwrap_or_else(|| panic!("no local instant for {y}-{m}-{d} {h}:{min}:{s}"))
        .timestamp_millis()
}

fn date(y: i32, m: u32, d: u32) -> NaiveDate {
    NaiveDate::from_ymd_opt(y, m, d).unwrap()
}

fn expect_split(input: &str, person: &str, chips: &[&str], label: &str) {
    let got = daily::split_body(input);
    assert_eq!(got.person, person, "{label}: person of {input:?}");
    assert_eq!(got.chips, chips, "{label}: chips of {input:?}");
}

fn assemble_strs(person: &str, chips: &[&str]) -> String {
    daily::assemble(person, chips)
}

// C3 assemble fixtures (outputs), reused by the round-trip test.
const J1: &str = "Morning pages\n<!-- memex:topics -->\n[[Player Loop~about]]\n[[Sleep~about]]\n";
const J2: &str = "Morning pages\n<!-- memex:topics -->\n";
const J3: &str = "<!-- memex:topics -->\n";

// ---------- AC 1: split_body, C3 fixtures S1-S8 ----------

#[test]
fn split_body_passes_c3_fixtures_s1_to_s8() {
    expect_split(
        "Morning pages\n\n- buy milk\n",
        "Morning pages\n\n- buy milk\n",
        &[],
        "S1",
    );
    expect_split(
        "Morning pages\n<!-- memex:topics -->\n[[Player Loop~about]]\n[[Sleep~about]]\n",
        "Morning pages\n",
        &["Player Loop", "Sleep"],
        "S2",
    );
    expect_split("<!-- memex:topics -->\n", "", &[], "S3");
    expect_split(
        "a\n<!-- memex:topics -->  \r\n[[X~about]]\r\n",
        "a\n",
        &["X"],
        "S4",
    );
    expect_split(
        "see <!-- memex:topics --> here\n",
        "see <!-- memex:topics --> here\n",
        &[],
        "S5",
    );
    expect_split(
        "a\n<!-- memex:topics -->\n[[X~about]]\nlate thought\n",
        "a\nlate thought\n",
        &["X"],
        "S6",
    );
    expect_split("a\n<!-- memex:topics -->\nlate", "a\nlate\n", &[], "S7");
    expect_split(
        "a\n<!-- memex:topics -->\n\n<!-- memex:topics -->\n[[X~about]]\n",
        "a\n",
        &["X"],
        "S8",
    );
}

#[test]
fn split_body_returns_a_daily_body_value() {
    assert_eq!(
        daily::split_body("Morning pages\n<!-- memex:topics -->\n[[Sleep~about]]\n"),
        DailyBody {
            person: "Morning pages\n".into(),
            chips: vec!["Sleep".into()],
            tags: vec![],
        }
    );
    assert_eq!(daily::TOPICS_MARKER, "<!-- memex:topics -->");
}

#[test]
fn split_body_without_marker_keeps_the_whole_body_as_person() {
    expect_split("", "", &[], "empty body");
    expect_split("no newline", "no newline", &[], "no trailing newline");
    expect_split(
        "[[X~about]]\n",
        "[[X~about]]\n",
        &[],
        "chip-like line, no marker",
    );
    expect_split(
        "x <!-- memex:topics -->\n[[X~about]]\n",
        "x <!-- memex:topics -->\n[[X~about]]\n",
        &[],
        "marker with prefix text is not the marker",
    );
    expect_split(
        " <!-- memex:topics -->\n[[X~about]]\n",
        " <!-- memex:topics -->\n[[X~about]]\n",
        &[],
        "leading space: only trailing spaces are trimmed",
    );
    expect_split(
        "<!-- memex:topics -->x\n[[X~about]]\n",
        "<!-- memex:topics -->x\n[[X~about]]\n",
        &[],
        "marker with suffix text is not the marker",
    );
}

#[test]
fn split_body_ignores_trailing_spaces_and_cr_on_marker_and_chips() {
    expect_split(
        "a\n<!-- memex:topics -->\n[[X~about]]   \n[[Y~about]] \r\n",
        "a\n",
        &["X", "Y"],
        "trailing spaces on chips",
    );
    expect_split(
        "a\r\n<!-- memex:topics -->\r\n[[X~about]]\n",
        "a\r\n",
        &["X"],
        "CRLF person kept verbatim",
    );
    expect_split(
        "a\n<!-- memex:topics -->",
        "a\n",
        &[],
        "marker as the last line without a newline",
    );
}

#[test]
fn split_body_keeps_chip_order_and_reads_a_last_chip_without_newline() {
    expect_split(
        "a\n<!-- memex:topics -->\n[[Zeta~about]]\n[[Alpha~about]]\n[[Mid~about]]",
        "a\n",
        &["Zeta", "Alpha", "Mid"],
        "order preserved, last line unterminated",
    );
    expect_split(
        "a\n<!-- memex:topics -->\n[[Café 😀~about]]\n",
        "a\n",
        &["Café 😀"],
        "multi-byte chip title",
    );
}

#[test]
fn split_body_moves_stray_text_below_the_marker_to_the_end_of_person() {
    expect_split(
        "a\n<!-- memex:topics -->\n[[X~about]]\nfoo\n[[Y~about]]\nbar\n",
        "a\nfoo\nbar\n",
        &["X", "Y"],
        "stray lines interleaved with chips keep their order",
    );
    expect_split(
        "a\n<!-- memex:topics -->\n- [[X~about]]\n[[~about]]\n",
        "a\n- [[X~about]]\n[[~about]]\n",
        &[],
        "near-miss chip lines are stray text",
    );
    expect_split(
        "a\n<!-- memex:topics -->\n[[X~extends]]\n[[X~about]] tail\n",
        "a\n[[X~extends]]\n[[X~about]] tail\n",
        &[],
        "other kinds and trailing text are stray text",
    );
    expect_split(
        "a\n\n<!-- memex:topics -->\nlate thought\n",
        "a\n\nlate thought\n",
        &[],
        "person ending in a blank line keeps it",
    );
}

#[test]
fn split_body_with_empty_person_adds_stray_text_without_a_leading_newline() {
    expect_split(
        "<!-- memex:topics -->\nlate\n[[X~about]]\n",
        "late\n",
        &["X"],
        "empty person + stray",
    );
}

#[test]
fn split_body_drops_blank_lines_and_repeated_marker_lines_below_the_marker() {
    expect_split(
        "a\n<!-- memex:topics -->\n\n\n[[X~about]]\n\n<!-- memex:topics -->  \n[[Y~about]]\n\n",
        "a\n",
        &["X", "Y"],
        "many blanks and markers",
    );
    expect_split(
        "a\n<!-- memex:topics -->\n   \n \r\n[[X~about]]\n",
        "a\n",
        &["X"],
        "lines of only spaces and CR are blank",
    );
}

// ---------- AC 2: assemble, C3 fixtures J1-J3 and round trip ----------

#[test]
fn assemble_passes_c3_fixtures_j1_to_j3() {
    assert_eq!(
        assemble_strs("Morning pages\n", &["Player Loop", "Sleep"]),
        J1,
        "J1"
    );
    assert_eq!(assemble_strs("Morning pages", &[]), J2, "J2");
    assert_eq!(assemble_strs("", &[]), J3, "J3");
}

#[test]
fn assemble_keeps_the_person_text_verbatim() {
    assert_eq!(
        assemble_strs("a\n\n", &["X"]),
        "a\n\n<!-- memex:topics -->\n[[X~about]]\n"
    );
    assert_eq!(
        assemble_strs("café 😀", &["Été"]),
        "café 😀\n<!-- memex:topics -->\n[[Été~about]]\n"
    );
    assert_eq!(
        assemble_strs("", &["X"]),
        "<!-- memex:topics -->\n[[X~about]]\n",
        "empty person gets no leading newline"
    );
    // Owned chip titles work as well as borrowed ones.
    let owned: Vec<String> = vec!["Player Loop".into(), "Sleep".into()];
    assert_eq!(daily::assemble("Morning pages\n", &owned), J1);
}

#[test]
fn assemble_of_split_round_trips_j1_to_j3_outputs() {
    for b in [J1, J2, J3] {
        let parts = daily::split_body(b);
        assert_eq!(daily::assemble(&parts.person, &parts.chips), b, "{b:?}");
    }
}

#[test]
fn assemble_of_split_normalizes_s6_s7_and_s8() {
    let cases = [
        (
            "a\n<!-- memex:topics -->\n[[X~about]]\nlate thought\n",
            "a\nlate thought\n<!-- memex:topics -->\n[[X~about]]\n",
        ),
        (
            "a\n<!-- memex:topics -->\nlate",
            "a\nlate\n<!-- memex:topics -->\n",
        ),
        (
            "a\n<!-- memex:topics -->\n\n<!-- memex:topics -->\n[[X~about]]\n",
            "a\n<!-- memex:topics -->\n[[X~about]]\n",
        ),
        ("Morning pages", "Morning pages\n<!-- memex:topics -->\n"),
    ];
    for (input, want) in cases {
        let parts = daily::split_body(input);
        assert_eq!(
            daily::assemble(&parts.person, &parts.chips),
            want,
            "{input:?}"
        );
    }
}

// ---------- AC 3: today_with_clock and resolve_date ----------

#[test]
fn today_with_clock_at_noon_utc_returns_that_date() {
    let clock = noon_utc(2026, 9, 5);
    let today = daily::today_with_clock(&clock);
    assert_eq!(today, date(2026, 9, 5));
    assert_eq!(today.weekday(), Weekday::Sat, "2026-09-05 is a Saturday");
    assert_eq!(today.to_string(), "2026-09-05");

    assert_eq!(
        daily::today_with_clock(&noon_utc(2026, 12, 31)),
        date(2026, 12, 31)
    );
    assert_eq!(
        daily::today_with_clock(&noon_utc(2028, 2, 29)),
        date(2028, 2, 29)
    );
}

#[test]
fn today_with_clock_follows_local_midnight() {
    // Instants built in the machine's local zone: the last second of a local
    // day and the first second of the next one fall on different dates
    // whatever the test machine's offset is.
    let last = local_ms(2026, 9, 5, 23, 59, 59);
    assert_eq!(daily::today_with_clock(&FixedClock(last)), date(2026, 9, 5));
    assert_eq!(
        daily::today_with_clock(&FixedClock(last + 1_000)),
        date(2026, 9, 6),
        "one second after local 23:59:59 is the next day"
    );
    assert_eq!(
        daily::today_with_clock(&FixedClock(local_ms(2026, 9, 6, 0, 0, 0))),
        date(2026, 9, 6)
    );
    assert_eq!(
        daily::today_with_clock(&FixedClock(local_ms(2026, 9, 5, 0, 0, 0) - 1)),
        date(2026, 9, 4),
        "one millisecond before local midnight is the previous day"
    );
}

#[test]
fn today_with_clock_matches_the_local_calendar_across_dst_weeks() {
    // Every hour across the 2026 northern- and southern-hemisphere DST
    // changes: the date is the local calendar date of the instant.
    let windows = [
        (date(2026, 3, 6), 5),
        (date(2026, 3, 27), 4),
        (date(2026, 4, 3), 5),
        (date(2026, 9, 25), 5),
        (date(2026, 10, 2), 4),
        (date(2026, 10, 23), 13),
    ];
    for (start, days) in windows {
        let start_ms = Utc
            .from_utc_datetime(&start.and_hms_opt(0, 0, 0).unwrap())
            .timestamp_millis();
        for hour in 0..(days * 24) {
            let ms = start_ms + Duration::hours(hour).num_milliseconds();
            let want = Local.timestamp_millis_opt(ms).unwrap().date_naive();
            assert_eq!(
                daily::today_with_clock(&FixedClock(ms)),
                want,
                "instant {ms} ms"
            );
        }
    }
}

#[test]
fn resolve_date_none_is_today_and_some_parses_iso() {
    let clock = noon_utc(2026, 9, 5);
    assert_eq!(daily::resolve_date(None, &clock).unwrap(), date(2026, 9, 5));
    assert_eq!(
        daily::resolve_date(None, &clock).unwrap(),
        daily::today_with_clock(&clock)
    );
    assert_eq!(
        daily::resolve_date(Some("2026-09-05"), &clock).unwrap(),
        date(2026, 9, 5)
    );
    // An explicit date ignores the clock.
    assert_eq!(
        daily::resolve_date(Some("2025-01-31"), &clock).unwrap(),
        date(2025, 1, 31)
    );
    assert_eq!(
        daily::resolve_date(Some("2028-02-29"), &clock).unwrap(),
        date(2028, 2, 29),
        "a real leap day"
    );
}

#[test]
fn resolve_date_rejects_non_calendar_dates_with_invalid_date() {
    let clock = noon_utc(2026, 9, 5);
    for bad in [
        "2026-02-30",
        "2026-9-5",
        "Groceries",
        "",
        "2026-02-29",
        "2026-13-01",
        "2026-00-10",
        "2026-09-00",
        "2026-09-5",
        "20260905",
        "2026/09/05",
        " 2026-09-05",
        "2026-09-05 ",
        "2026-09-05T00:00",
        "+2026-09-05",
    ] {
        match daily::resolve_date(Some(bad), &clock) {
            Err(MemexError::InvalidDate(_)) => {}
            other => panic!("{bad:?}: expected InvalidDate, got {other:?}"),
        }
    }
}

// ---------- AC 15: ReviewState labels ----------

#[test]
fn review_state_as_str_returns_c2_labels() {
    assert_eq!(ReviewState::Unreviewed.as_str(), "Unreviewed");
    assert_eq!(ReviewState::Reviewed.as_str(), "Reviewed");
    assert_eq!(
        ReviewState::ChangedSinceReview.as_str(),
        "Changed since review"
    );
}

// ---------- Implementer additions (WI #7) ----------

#[test]
fn append_to_person_uses_the_c3_1_separator() {
    let cases = [
        ("", "new", "new\n"),
        ("old", "new", "old\n\nnew\n"),
        ("old\n", "new", "old\n\nnew\n"),
        ("old\n\n", "new", "old\n\nnew\n"),
        ("old\n\n\n", "new", "old\n\n\nnew\n"),
        ("old\n", "two\nlines", "old\n\ntwo\nlines\n"),
    ];
    for (person, text, want) in cases {
        assert_eq!(
            daily::append_to_person(person, text),
            want,
            "{person:?} + {text:?}"
        );
    }
}

#[test]
fn parse_iso_date_accepts_only_strict_calendar_dates() {
    assert_eq!(
        daily::parse_iso_date("2026-09-05").unwrap(),
        date(2026, 9, 5)
    );
    for bad in [
        "2026-09-5",
        "2026-9-05",
        "2026-02-30",
        "x026-09-05",
        "2026_09_05",
    ] {
        assert!(
            matches!(daily::parse_iso_date(bad), Err(MemexError::InvalidDate(_))),
            "{bad:?}"
        );
    }
}

#[test]
fn is_daily_matches_the_role_exactly() {
    use serde_json::json;
    assert!(daily::is_daily(&json!({ "role": "daily" })));
    for fm in [
        json!({}),
        json!({ "role": "Daily" }),
        json!({ "role": "topic" }),
        json!({ "role": null }),
        json!(null),
    ] {
        assert!(!daily::is_daily(&fm), "{fm}");
    }
}

// ---------- WI #238 (T2): footer tag lines and the non-daily split ----------
//
// `app/test/fixtures/tags/footer_split.json` is the contract the Dart port
// (`segments.dart`) is held to as well (D13). The named tests below it pin
// each arm of the tag-line predicate and the fence rule on their own.

fn footer_split_fixture() -> serde_json::Value {
    let path = std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../../app/test/fixtures/tags/footer_split.json");
    let raw =
        std::fs::read_to_string(&path).unwrap_or_else(|e| panic!("read {}: {e}", path.display()));
    serde_json::from_str(&raw).expect("footer_split.json is JSON")
}

fn fixture_strs(v: &serde_json::Value, what: &str) -> Vec<String> {
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

fn fixture_str<'a>(v: &'a serde_json::Value, key: &str) -> &'a str {
    v[key]
        .as_str()
        .unwrap_or_else(|| panic!("{key} is a string in {v}"))
}

fn split_parts(body: &DailyBody) -> (String, Vec<String>, Vec<String>) {
    (body.person.clone(), body.chips.clone(), body.tags.clone())
}

#[test]
fn footer_split_fixture_rows_all_pass() {
    let fixture = footer_split_fixture();
    assert_eq!(fixture["marker"], daily::TOPICS_MARKER);
    let rows = fixture["split"]
        .as_array()
        .expect("footer_split.json has a split array");

    // One row per consumer decision the WI's AC names, so the table can't
    // silently lose one.
    let decisions: Vec<&str> = rows.iter().map(|r| fixture_str(r, "decision")).collect();
    for required in [
        "chip line",
        "tag line",
        "legacy tag line",
        "heading",
        "double hash",
        "blank",
        "repeated marker",
        "fenced marker",
        "no marker",
    ] {
        assert!(
            decisions.contains(&required),
            "footer_split.json has a {required:?} row"
        );
    }

    let mut failures = Vec::new();
    let mut checked = 0;
    for row in rows {
        let input = fixture_str(row, "input");
        let want = (
            fixture_str(row, "person").to_string(),
            fixture_strs(&row["chips"], "chips"),
            fixture_strs(&row["tags"], "tags"),
        );
        for on in fixture_strs(&row["on"], "on") {
            let got = match on.as_str() {
                "daily" => split_parts(&daily::split_body(input)),
                "note" => split_parts(&daily::split_note_body(input)),
                other => panic!("unknown splitter {other:?}"),
            };
            checked += 1;
            if got != want {
                failures.push(format!(
                    "{on} / {}: {input:?}\n  want {want:?}\n  got  {got:?}",
                    fixture_str(row, "name")
                ));
            }
        }
    }
    let assembles = fixture["assemble"]
        .as_array()
        .expect("footer_split.json has an assemble array");
    for row in assembles {
        checked += 1;
        let chips = fixture_strs(&row["chips"], "chips");
        let got = daily::assemble(fixture_str(row, "person"), &chips);
        if got != fixture_str(row, "body") {
            failures.push(format!(
                "assemble / {}: got {got:?}",
                fixture_str(row, "name")
            ));
        }
    }
    assert!(
        failures.is_empty(),
        "{} of {checked} footer_split.json checks failed:\n{}",
        failures.len(),
        failures.join("\n")
    );
}

#[test]
fn split_body_drops_footer_tag_lines_and_reports_their_names() {
    let m = daily::TOPICS_MARKER;
    // Tag lines: `#` then anything but a space or `#`.
    for (line, name) in [
        ("#work", "work"),
        ("#My Tag", "My Tag"),
        ("#123", "123"),
        ("#x  \r", "x"),
        ("#\u{e9}t\u{e9}", "\u{e9}t\u{e9}"),
    ] {
        let body = format!("Day.\n{m}\n[[X~about]]\n{line}\n");
        for (splitter, got) in [
            ("daily", daily::split_body(&body)),
            ("note", daily::split_note_body(&body)),
        ] {
            assert_eq!(
                got.person, "Day.\n",
                "{splitter}: {line:?} is not person text"
            );
            assert_eq!(got.chips, ["X"], "{splitter}: {line:?}");
            assert_eq!(got.tags, [name], "{splitter}: {line:?} is a tag line");
        }
    }
    // Stray lines: `# `, `##`, a bare `#`, an indented `#x`, text then `#y`.
    for line in ["# Heading", "##x", "#", "  #x", "x #y"] {
        let body = format!("Day.\n{m}\n[[X~about]]\n{line}\n");
        for (splitter, got) in [
            ("daily", daily::split_body(&body)),
            ("note", daily::split_note_body(&body)),
        ] {
            assert_eq!(
                got.person,
                format!("Day.\n{line}\n"),
                "{splitter}: {line:?} moves to the person section"
            );
            assert_eq!(got.chips, ["X"], "{splitter}: {line:?}");
            assert!(got.tags.is_empty(), "{splitter}: {line:?}: {:?}", got.tags);
        }
    }
}

#[test]
fn split_note_body_ignores_a_marker_inside_fenced_code() {
    let m = daily::TOPICS_MARKER;
    for fence in ["```", "~~~", "````"] {
        let body = format!("Code:\n{fence}\n{m}\n[[X~about]]\n{fence}\nAfter.\n");
        let got = daily::split_note_body(&body);
        assert_eq!(got.person, body, "{fence}: the fenced marker is body text");
        assert!(got.chips.is_empty() && got.tags.is_empty(), "{fence}");

        let with_footer = format!("{body}{m}\n[[Y~about]]\n#y\n");
        let got = daily::split_note_body(&with_footer);
        assert_eq!(
            got.person, body,
            "{fence}: the marker after the fence splits"
        );
        assert_eq!(got.chips, ["Y"], "{fence}");
        assert_eq!(got.tags, ["y"], "{fence}");
    }
    // A marker outside any fence splits exactly like split_body.
    let plain = format!("Notes.\n{m}\n[[X~about]]\n#x\nlate\n");
    assert_eq!(daily::split_note_body(&plain), daily::split_body(&plain));
    assert_eq!(daily::split_note_body(&plain).person, "Notes.\nlate\n");
    // No marker at all: the whole body, even without a final newline.
    for body in ["", "Last line", "a\n\n- b\n"] {
        let got = daily::split_note_body(body);
        assert_eq!(got.person, body);
        assert!(got.chips.is_empty() && got.tags.is_empty());
    }
}
