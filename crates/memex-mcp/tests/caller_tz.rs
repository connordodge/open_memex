//! WI #76 (R3a, rulings D5, D10a): `caller_tz::{parse_utc_offset,
//! format_utc_offset}`, the only `X-Memex-UTC-Offset` parser and formatter.
//!
//! Grammar `^[+-]\d{2}:\d{2}$` with ASCII digits, minutes 00-59, magnitude at
//! most 14:00; `-00:30` is minus thirty minutes. The cases come from #74's
//! shared fixture `app/test/fixtures/api_v1/server/utc_offsets.json`, read
//! unchanged (#77's Dart formatter passes the same file).

#[path = "support/api_fixtures.rs"]
mod api_fixtures;

use memex_core::FixedOffset;
use memex_mcp::caller_tz::{format_utc_offset, parse_utc_offset};

fn offset(minutes: i32) -> FixedOffset {
    FixedOffset::east_opt(minutes * 60).unwrap_or_else(|| panic!("bad offset {minutes} min"))
}

fn minutes(offset: FixedOffset) -> i32 {
    offset.local_minus_utc() / 60
}

#[test]
fn parse_utc_offset_accepts_every_valid_fixture_row() {
    let cases = api_fixtures::load_utc_offsets();
    // The rows AC 1 names must be in the fixture this test reads.
    for (header, want) in [
        ("-00:30", -30),
        ("+14:00", 840),
        ("-12:00", -720),
        ("-14:00", -840),
    ] {
        assert_eq!(
            cases.valid.get(header),
            Some(&want),
            "utc_offsets.json valid rows must hold {header} -> {want}"
        );
    }
    let mut failures = Vec::new();
    for (header, want) in &cases.valid {
        let got = parse_utc_offset(header);
        if got != Some(offset(*want)) {
            failures.push(format!(
                "{header:?}: got {:?}, want {want} min",
                got.map(minutes)
            ));
        }
    }
    assert!(failures.is_empty(), "valid rows: {failures:#?}");
}

#[test]
fn parse_utc_offset_minus_zero_hours_is_negative() {
    let parsed = parse_utc_offset("-00:30").expect("-00:30 is valid");
    assert_eq!(
        minutes(parsed),
        -30,
        "-00:30 is minus thirty minutes, not +30"
    );
    assert_eq!(parsed.local_minus_utc(), -1800);
    assert_eq!(parse_utc_offset("-00:59").map(minutes), Some(-59));
    assert_eq!(parse_utc_offset("+00:01").map(minutes), Some(1));
}

#[test]
fn parse_utc_offset_rejects_every_invalid_fixture_row() {
    let cases = api_fixtures::load_utc_offsets();
    for header in ["+15:00", "+5:00", "+05:60", "+14:01", "05:30", "+0530", ""] {
        assert!(
            cases.invalid.iter().any(|h| h == header),
            "utc_offsets.json invalid rows must hold {header:?}"
        );
    }
    let accepted: Vec<_> = cases
        .invalid
        .iter()
        .filter_map(|h| parse_utc_offset(h).map(|o| format!("{h:?} -> {} min", minutes(o))))
        .collect();
    assert!(
        accepted.is_empty(),
        "invalid rows were accepted: {accepted:#?}"
    );
}

/// Malformed values beyond the fixture that a lenient parser lets through:
/// signs inside the fields (`"-5".parse::<i32>()` succeeds), surrounding
/// whitespace and a trailing newline (`$` before `\n`), non-ASCII digits
/// (`\d` is Unicode in Rust's regex), extra fields, bounds.
#[test]
fn parse_utc_offset_rejects_lenient_parser_inputs() {
    let malformed = [
        "+-5:30",
        "-+5:30",
        "+05:-3",
        "+05:+3",
        "+ 5:30",
        " +05:30",
        "+05:30 ",
        "+05:30\n",
        "\t+05:30",
        "+05:30:00",
        "++05:30",
        "+05.30",
        "+05;30",
        "+0５:30",
        "+٠٥:٣٠",
        "+99:99",
        "-15:00",
        "+14:59",
        "-14:30",
        "+24:00",
        "abc",
        "+",
        ":",
        "+05:",
        "+:30",
        "UTC+05:30",
        "+05:30Z",
    ];
    let accepted: Vec<_> = malformed
        .iter()
        .filter_map(|h| parse_utc_offset(h).map(|o| format!("{h:?} -> {} min", minutes(o))))
        .collect();
    assert!(
        accepted.is_empty(),
        "malformed values were accepted: {accepted:#?}"
    );
}

#[test]
fn parse_utc_offset_accepts_the_grammar_bounds() {
    let cases = [
        ("+13:59", 839),
        ("-13:59", -839),
        ("+14:00", 840),
        ("-14:00", -840),
        ("+00:00", 0),
        ("-00:00", 0),
        ("+00:59", 59),
        ("+12:45", 765),
        ("-03:00", -180),
        ("+09:00", 540),
        ("-10:10", -610),
    ];
    for (header, want) in cases {
        assert_eq!(
            parse_utc_offset(header).map(minutes),
            Some(want),
            "parse_utc_offset({header:?})"
        );
    }
}

#[test]
fn format_utc_offset_renders_every_format_fixture_row() {
    let cases = api_fixtures::load_utc_offsets();
    for (want_min, want_header) in [(-30, "-00:30"), (0, "+00:00"), (345, "+05:45")] {
        assert_eq!(
            cases.format.get(&want_min).map(String::as_str),
            Some(want_header),
            "utc_offsets.json format rows must hold {want_min} -> {want_header}"
        );
    }
    let mut failures = Vec::new();
    for (mins, want) in &cases.format {
        let got = format_utc_offset(offset(*mins));
        if &got != want {
            failures.push(format!("{mins} min: got {got:?}, want {want:?}"));
        }
    }
    assert!(failures.is_empty(), "format rows: {failures:#?}");
}

#[test]
fn format_utc_offset_round_trips_every_minute_in_range() {
    let mut failures = Vec::new();
    for m in -840..=840 {
        let header = format_utc_offset(offset(m));
        let shaped = header.len() == 6
            && header.is_ascii()
            && matches!(header.as_bytes()[0], b'+' | b'-')
            && header.as_bytes()[3] == b':';
        let sign_ok = if m < 0 {
            header.starts_with('-')
        } else {
            header.starts_with('+')
        };
        let back = parse_utc_offset(&header).map(minutes);
        if !shaped || !sign_ok || back != Some(m) {
            failures.push(format!("{m} min -> {header:?} -> {back:?}"));
        }
    }
    assert!(
        failures.is_empty(),
        "{} of 1681 offsets fail: {:#?}",
        failures.len(),
        &failures[..failures.len().min(20)]
    );
}

#[test]
fn format_utc_offset_from_runtime_parsed_offsets_is_canonical() {
    // Built from run-time values: every valid fixture header re-formats to
    // the canonical header for its minutes.
    let cases = api_fixtures::load_utc_offsets();
    for (header, mins) in &cases.valid {
        let parsed = parse_utc_offset(header).unwrap_or_else(|| panic!("{header:?} is valid"));
        let canonical = format_utc_offset(offset(*mins));
        assert_eq!(format_utc_offset(parsed), canonical, "{header:?}");
        assert_eq!(&canonical, header, "{header:?} is already canonical");
    }
    assert_eq!(
        format_utc_offset(parse_utc_offset("-00:00").expect("-00:00 is valid")),
        "+00:00",
        "zero always formats as +00:00"
    );
}
