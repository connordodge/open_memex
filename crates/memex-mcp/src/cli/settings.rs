//! `memex settings` (CONTRACTS C2.11): read and write vault settings.

use std::path::PathBuf;

use clap::{Args, Subcommand};

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
    /// New value.
    #[arg(long)]
    pub value: String,
}

pub fn run(args: SettingsArgs) -> anyhow::Result<()> {
    match args.command {
        SettingsCommand::Get(_) => super::not_implemented("settings get"),
        SettingsCommand::Set(_) => super::not_implemented("settings set"),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn stubs_report_not_implemented() {
        let cases = [
            (
                SettingsCommand::Get(SettingsGetArgs {
                    vault: PathBuf::from("v"),
                    key: "k".into(),
                }),
                "settings get",
            ),
            (
                SettingsCommand::Set(SettingsSetArgs {
                    vault: PathBuf::from("v"),
                    key: "k".into(),
                    value: "3".into(),
                }),
                "settings set",
            ),
        ];
        for (command, name) in cases {
            let err = run(SettingsArgs { command }).unwrap_err();
            assert_eq!(
                err.to_string(),
                format!("memex {name}: not implemented yet")
            );
        }
    }
}
