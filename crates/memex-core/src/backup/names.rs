//! Backup file names (Spec #315 req 4, 5; architecture D10). Filler: R1a.
//!
//! Final: `<label>-<YYYYMMDDTHHMMSSZ>-<vault_id>.memex.zip`; partial:
//! `"." + final + ".partial"`. Shared cases: `app/test/fixtures/backup/file_names.json`.

/// A final backup file name, parsed from the right.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ParsedName {
    pub label: String,
    /// `YYYYMMDDTHHMMSSZ`; newest is the lexically greatest.
    pub timestamp: String,
    pub vault_id: String,
}

/// The label for a vault folder's name: every character outside
/// `[A-Za-z0-9_-]` becomes `-`, cut to 64 characters.
pub fn label_for(_folder_name: &str) -> String {
    String::new()
}

/// The final file name of a backup taken at `at_ms` (UTC).
pub fn file_name(_label: &str, _at_ms: i64, _vault_id: &str) -> String {
    String::new()
}

/// The temporary name `final_name` is written under.
pub fn partial_name(_final_name: &str) -> String {
    String::new()
}

/// `Some` when `name` is a final backup file name (case-sensitive).
pub fn parse_file_name(_name: &str) -> Option<ParsedName> {
    None
}

/// True when `name` is a `.partial` of a backup of `vault_id`.
pub fn is_partial_for(_name: &str, _vault_id: &str) -> bool {
    false
}
