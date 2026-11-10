//! Backup file names (Spec #315 req 4, 5; architecture D10). Filler: R1a.
//!
//! Final: `<label>-<YYYYMMDDTHHMMSSZ>-<vault_id>.memex.zip`; partial:
//! `"." + final + ".partial"`. Shared cases: `app/test/fixtures/backup/file_names.json`.
//!
//! The grammar is ASCII only, so the parser works on bytes: a non-ASCII
//! byte fails every class check and no slice ever cuts a character.

use chrono::DateTime;

/// A final backup file name, parsed from the right.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ParsedName {
    pub label: String,
    /// `YYYYMMDDTHHMMSSZ`; newest is the lexically greatest.
    pub timestamp: String,
    pub vault_id: String,
}

const SUFFIX: &str = ".memex.zip";
const PARTIAL_PREFIX: &str = ".";
const PARTIAL_SUFFIX: &str = ".partial";
const LABEL_MAX: usize = 64;
const TIMESTAMP_LEN: usize = 16;
const VAULT_ID_LEN: usize = 26;

fn is_label_byte(b: u8) -> bool {
    b.is_ascii_alphanumeric() || b == b'_' || b == b'-'
}

/// `\d{8}T\d{6}Z`, ASCII digits only.
fn is_timestamp(t: &[u8]) -> bool {
    t.len() == TIMESTAMP_LEN
        && t[..8].iter().all(u8::is_ascii_digit)
        && t[8] == b'T'
        && t[9..15].iter().all(u8::is_ascii_digit)
        && t[15] == b'Z'
}

/// The label for a vault folder's name: every character outside
/// `[A-Za-z0-9_-]` becomes `-`, cut to 64 characters.
pub fn label_for(folder_name: &str) -> String {
    folder_name
        .chars()
        .take(LABEL_MAX)
        .map(|c| {
            if c.is_ascii() && is_label_byte(c as u8) {
                c
            } else {
                '-'
            }
        })
        .collect()
}

/// The final file name of a backup taken at `at_ms` (UTC).
pub fn file_name(label: &str, at_ms: i64, vault_id: &str) -> String {
    // Out of chrono's range (beyond year ±262,000) falls back to the epoch;
    // no clock reads such a value.
    let at = DateTime::from_timestamp_millis(at_ms).unwrap_or_default();
    format!("{label}-{}-{vault_id}{SUFFIX}", at.format("%Y%m%dT%H%M%SZ"))
}

/// The temporary name `final_name` is written under.
pub fn partial_name(final_name: &str) -> String {
    format!("{PARTIAL_PREFIX}{final_name}{PARTIAL_SUFFIX}")
}

/// `Some` when `name` is a final backup file name (case-sensitive).
pub fn parse_file_name(name: &str) -> Option<ParsedName> {
    let stem = name.strip_suffix(SUFFIX)?.as_bytes();
    // From the right: vault_id, `-`, timestamp, `-`, label.
    let id_at = stem.len().checked_sub(VAULT_ID_LEN)?;
    let vault_id = &stem[id_at..];
    if !vault_id.iter().all(u8::is_ascii_alphanumeric) {
        return None;
    }
    let ts_at = id_at.checked_sub(1 + TIMESTAMP_LEN)?;
    if stem[id_at - 1] != b'-' {
        return None;
    }
    let timestamp = &stem[ts_at..id_at - 1];
    if !is_timestamp(timestamp) {
        return None;
    }
    let label_end = ts_at.checked_sub(1)?;
    if stem[label_end] != b'-' {
        return None;
    }
    let label = &stem[..label_end];
    if label.is_empty() || label.len() > LABEL_MAX || !label.iter().copied().all(is_label_byte) {
        return None;
    }
    // Every byte checked above is ASCII, so each part is valid UTF-8.
    let text = |b: &[u8]| String::from_utf8(b.to_vec()).ok();
    Some(ParsedName {
        label: text(label)?,
        timestamp: text(timestamp)?,
        vault_id: text(vault_id)?,
    })
}

/// True when `name` is a `.partial` of a backup of `vault_id`: a dot, a
/// final backup name of that vault (by the same grammar), then `.partial`.
pub fn is_partial_for(name: &str, vault_id: &str) -> bool {
    name.strip_prefix(PARTIAL_PREFIX)
        .and_then(|rest| rest.strip_suffix(PARTIAL_SUFFIX))
        .and_then(parse_file_name)
        .is_some_and(|p| p.vault_id == vault_id)
}
