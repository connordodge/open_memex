//! The `X-Memex-UTC-Offset` grammar (D5): the only parser and formatter of a
//! caller's UTC offset. Grammar `^[+-]\d{2}:\d{2}$` (ASCII digits), minutes
//! 00-59, magnitude at most 14:00; `-00:30` is minus thirty minutes.
//! Checked against `app/test/fixtures/api_v1/server/utc_offsets.json`.

use memex_core::FixedOffset;

/// Parses an `X-Memex-UTC-Offset` value, or `None` when it is malformed.
pub fn parse_utc_offset(_header: &str) -> Option<FixedOffset> {
    todo!("#76: parse ±HH:MM")
}

/// Renders `offset` as `±HH:MM` (zero is `+00:00`).
pub fn format_utc_offset(_offset: FixedOffset) -> String {
    todo!("#76: format ±HH:MM")
}
