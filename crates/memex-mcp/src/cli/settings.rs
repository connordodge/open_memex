//! `memex settings` (CONTRACTS C2.11): read and write vault settings.

use std::path::PathBuf;

use clap::{Args, Subcommand};
use memex_core::{SystemClock, Vault};

use crate::ops::settings;

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

pub fn run(args: SettingsArgs) -> anyhow::Result<()> {
    let out = match args.command {
        SettingsCommand::Get(a) => {
            // `Vault::open` migrates a V4 vault to V5 (#18 relies on this).
            let mut vault = Vault::open(&a.vault)?;
            let input = settings::GetInput { key: a.key };
            settings::get(&mut vault, input, &SystemClock, None)?
        }
        SettingsCommand::Set(a) => {
            let mut vault = Vault::open(&a.vault)?;
            let input = settings::SetInput {
                key: a.key,
                value: a.value,
            };
            settings::set(&mut vault, input, &SystemClock, None)?
        }
    };
    println!("{}", serde_json::to_string(&out)?);
    Ok(())
}
