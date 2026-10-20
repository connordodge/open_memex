//! Settings ops: `memex settings get|set` (C2.11).

use memex_core::embedder::Embedder;
use memex_core::{vault_settings, Clock, Vault};
use serde::Serialize;

/// The input of [`get`].
#[derive(Debug, Clone, Default)]
pub struct GetInput {
    pub key: String,
}

/// The input of [`set`].
#[derive(Debug, Clone, Default)]
pub struct SetInput {
    pub key: String,
    /// The new value as given; validated by core (`setting_invalid`).
    pub value: String,
}

/// The `memex settings get|set` output line.
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct SettingOutput {
    pub vault_id: String,
    pub key: String,
    pub value: i64,
}

/// Reads one setting.
pub fn get(
    vault: &mut Vault,
    input: GetInput,
    clock: &dyn Clock,
    embedder: Option<&dyn Embedder>,
) -> anyhow::Result<SettingOutput> {
    let _ = (clock, embedder);
    let value = vault_settings::get_setting(vault, &input.key)?;
    Ok(SettingOutput {
        vault_id: vault.vault_id().to_string(),
        key: input.key,
        value,
    })
}

/// Changes one setting.
pub fn set(
    vault: &mut Vault,
    input: SetInput,
    clock: &dyn Clock,
    embedder: Option<&dyn Embedder>,
) -> anyhow::Result<SettingOutput> {
    let _ = (clock, embedder);
    let value = vault_settings::set_setting(vault, &input.key, &input.value)?;
    Ok(SettingOutput {
        vault_id: vault.vault_id().to_string(),
        key: input.key,
        value,
    })
}
