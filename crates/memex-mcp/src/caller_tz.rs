//! The `X-Memex-UTC-Offset` grammar (D5): the only parser and formatter of a
//! caller's UTC offset. Grammar `^[+-]\d{2}:\d{2}$` (ASCII digits), minutes
//! 00-59, magnitude at most 14:00; `-00:30` is minus thirty minutes.
//! Checked against `app/test/fixtures/api_v1/server/utc_offsets.json`.

use memex_core::FixedOffset;

/// Largest offset magnitude the grammar allows, in minutes (14:00).
const MAX_OFFSET_MINUTES: i32 = 14 * 60;

/// Parses an `X-Memex-UTC-Offset` value, or `None` when it is malformed.
pub fn parse_utc_offset(header: &str) -> Option<FixedOffset> {
    let &[sign, h1, h2, b':', m1, m2] = header.as_bytes() else {
        return None;
    };
    let sign = match sign {
        b'+' => 1,
        b'-' => -1,
        _ => return None,
    };
    let digit = |b: u8| b.is_ascii_digit().then(|| i32::from(b - b'0'));
    let hours = digit(h1)? * 10 + digit(h2)?;
    let mins = digit(m1)? * 10 + digit(m2)?;
    if mins > 59 {
        return None;
    }
    let magnitude = hours * 60 + mins;
    if magnitude > MAX_OFFSET_MINUTES {
        return None;
    }
    FixedOffset::east_opt(sign * magnitude * 60)
}

/// Renders `offset` as `±HH:MM` (zero is `+00:00`).
pub fn format_utc_offset(offset: FixedOffset) -> String {
    let total_minutes = offset.local_minus_utc() / 60;
    let sign = if total_minutes < 0 { '-' } else { '+' };
    let magnitude = total_minutes.abs();
    format!("{sign}{:02}:{:02}", magnitude / 60, magnitude % 60)
}
