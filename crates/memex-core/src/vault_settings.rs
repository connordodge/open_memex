//! Vault settings.
//!
//! Key/value rows in `vault_settings`. The only key today is
//! `smart_folder_max_depth`: an integer 1 to 5, read as 2 when no row exists.

use crate::vault::Vault;
use crate::Result;

/// The vault's `smart_folder_max_depth` (2 when no row exists).
pub fn smart_folder_max_depth(_vault: &Vault) -> Result<i64> {
    unimplemented!("vault_settings::smart_folder_max_depth")
}

/// Reads a setting. An unknown key is `SettingInvalid`.
pub fn get_setting(_vault: &Vault, _key: &str) -> Result<i64> {
    unimplemented!("vault_settings::get_setting")
}

/// Validates and stores a setting from its raw text (`memex settings set
/// --value`), returning the stored value. An unknown key, a non-integer or a
/// value outside 1..=5 is `SettingInvalid`.
pub fn set_setting(_vault: &mut Vault, _key: &str, _value: &str) -> Result<i64> {
    unimplemented!("vault_settings::set_setting")
}
