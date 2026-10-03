//! Vault settings.
//!
//! Key/value rows in `vault_settings`. The only key today is
//! `smart_folder_max_depth`: an integer 1 to 5, read as 2 when no row exists.

use std::ops::RangeInclusive;

use rusqlite::{params, OptionalExtension};

use crate::error::MemexError;
use crate::links::LinkKind;
use crate::vault::Vault;
use crate::Result;

/// The key of the Smart Folder depth limit.
pub const SMART_FOLDER_MAX_DEPTH: &str = "smart_folder_max_depth";

/// `smart_folder_max_depth` when the vault has no row for it.
pub const DEFAULT_SMART_FOLDER_MAX_DEPTH: i64 = 2;

/// The values `smart_folder_max_depth` accepts.
pub const SMART_FOLDER_MAX_DEPTH_RANGE: RangeInclusive<i64> = 1..=5;

/// The vault's `smart_folder_max_depth` (2 when no row exists).
pub fn smart_folder_max_depth(vault: &Vault) -> Result<i64> {
    let raw: Option<String> = vault
        .conn()
        .query_row(
            "SELECT value FROM vault_settings WHERE key = ?",
            params![SMART_FOLDER_MAX_DEPTH],
            |r| r.get(0),
        )
        .optional()?;
    match raw {
        None => Ok(DEFAULT_SMART_FOLDER_MAX_DEPTH),
        Some(raw) => raw.parse().map_err(|_| {
            MemexError::SettingInvalid(format!(
                "stored {SMART_FOLDER_MAX_DEPTH} is not an integer: {raw:?}"
            ))
        }),
    }
}

/// Reads a setting. An unknown key is `SettingInvalid`.
pub fn get_setting(vault: &Vault, key: &str) -> Result<i64> {
    check_key(key)?;
    smart_folder_max_depth(vault)
}

/// Validates and stores a setting from its raw text (`memex settings set
/// --value`), returning the stored value. An unknown key, a non-integer or a
/// value outside 1..=5 is `SettingInvalid`.
pub fn set_setting(vault: &mut Vault, key: &str, value: &str) -> Result<i64> {
    check_key(key)?;
    let range = SMART_FOLDER_MAX_DEPTH_RANGE;
    let parsed: i64 = value
        .parse()
        .ok()
        .filter(|n| range.contains(n))
        .ok_or_else(|| {
            MemexError::SettingInvalid(format!(
                "{key} must be an integer from {} to {}, got {value:?}",
                range.start(),
                range.end()
            ))
        })?;
    vault.conn().execute(
        "INSERT INTO vault_settings (key, value) VALUES (?1, ?2)
         ON CONFLICT(key) DO UPDATE SET value = excluded.value",
        params![key, parsed.to_string()],
    )?;
    Ok(parsed)
}

/// Every link kind an agent may use: the four built-ins, then each
/// user-defined kind present in `links`, alphabetically.
pub fn link_kinds(vault: &Vault) -> Result<Vec<String>> {
    let mut kinds: Vec<String> = [
        LinkKind::REFERENCES,
        LinkKind::EXTENDS,
        LinkKind::CONTRADICTS,
        LinkKind::EXAMPLE_OF,
    ]
    .map(String::from)
    .to_vec();
    let mut stmt = vault
        .conn()
        .prepare("SELECT DISTINCT link_kind FROM links ORDER BY link_kind")?;
    let present = stmt.query_map([], |r| r.get::<_, String>(0))?;
    for kind in present {
        let kind = kind?;
        if !kinds.contains(&kind) {
            kinds.push(kind);
        }
    }
    Ok(kinds)
}

fn check_key(key: &str) -> Result<()> {
    if key == SMART_FOLDER_MAX_DEPTH {
        Ok(())
    } else {
        Err(MemexError::SettingInvalid(format!(
            "unknown setting {key:?}; the only key is {SMART_FOLDER_MAX_DEPTH}"
        )))
    }
}
