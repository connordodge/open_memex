//! Settings ops: `memex settings get|set` (C2.11).

use memex_core::embedder::Embedder;
use memex_core::{Clock, Vault};
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
    let _ = (vault, input, clock, embedder);
    anyhow::bail!("ops::settings::get is not implemented yet (#73)")
}

/// Changes one setting.
pub fn set(
    vault: &mut Vault,
    input: SetInput,
    clock: &dyn Clock,
    embedder: Option<&dyn Embedder>,
) -> anyhow::Result<SettingOutput> {
    let _ = (vault, input, clock, embedder);
    anyhow::bail!("ops::settings::set is not implemented yet (#73)")
}
