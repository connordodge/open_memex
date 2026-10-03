//! `memex settings` (CONTRACTS C2.11): read and write vault settings.

use std::path::PathBuf;

use clap::{Args, Subcommand};
use memex_core::{vault_settings, Vault};
use serde::Serialize;

/// `memex settings <command>`
#[derive(Args, Debug)]
pub struct SettingsArgs {
    #[command(subcommand)]
    pub command: SettingsCommand,
}

#[derive(Subcommand, Debug)]
pub enum SettingsCommand {
    /// Print one setting.
    Get(SettingsGetArgs),
    /// Change one setting.
    Set(SettingsSetArgs),
}

/// `memex settings get --vault V --key K`
#[derive(Args, Debug)]
pub struct SettingsGetArgs {
    /// Vault directory.
    #[arg(long)]
    pub vault: PathBuf,
    /// Setting key (e.g. `smart_folder_max_depth`).
    #[arg(long)]
    pub key: String,
}

/// `memex settings set --vault V --key K --value X`
#[derive(Args, Debug)]
pub struct SettingsSetArgs {
    /// Vault directory.
    #[arg(long)]
    pub vault: PathBuf,
    /// Setting key (e.g. `smart_folder_max_depth`).
    #[arg(long)]
    pub key: String,
    /// New value. Hyphen values are accepted so `-1` reaches validation and
    /// fails as `setting_invalid`, not as a clap usage error.
    #[arg(long, allow_hyphen_values = true)]
    pub value: String,
}

/// C2.11: `vault_id` first, then the key and its integer value.
#[derive(Serialize)]
struct SettingOut<'a> {
    vault_id: &'a str,
    key: &'a str,
    value: i64,
}

fn print_setting(vault: &Vault, key: &str, value: i64) -> anyhow::Result<()> {
    let out = SettingOut {
        vault_id: vault.vault_id(),
        key,
        value,
    };
    println!("{}", serde_json::to_string(&out)?);
    Ok(())
}

pub fn run(args: SettingsArgs) -> anyhow::Result<()> {
    match args.command {
        SettingsCommand::Get(a) => {
            // `Vault::open` migrates a V4 vault to V5 (#18 relies on this).
            let vault = Vault::open(&a.vault)?;
            let value = vault_settings::get_setting(&vault, &a.key)?;
            print_setting(&vault, &a.key, value)
        }
        SettingsCommand::Set(a) => {
            let mut vault = Vault::open(&a.vault)?;
            let value = vault_settings::set_setting(&mut vault, &a.key, &a.value)?;
            print_setting(&vault, &a.key, value)
        }
    }
}
