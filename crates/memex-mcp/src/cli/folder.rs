//! `memex folder` (CONTRACTS C2.5–C2.10): Smart Folders and their members.

use std::path::PathBuf;

use clap::{ArgAction, Args, Subcommand};

/// `memex folder <command>`
#[derive(Args, Debug)]
pub struct FolderArgs {
    #[command(subcommand)]
    pub command: FolderCommand,
}

#[derive(Subcommand, Debug)]
pub enum FolderCommand {
    /// List every Smart Folder with its members, plus unsorted notes.
    Ls(FolderLsArgs),
    /// Create a Smart Folder.
    New(FolderNewArgs),
    /// Rename, re-parent or (un)pin a Smart Folder.
    Update(FolderUpdateArgs),
    /// Delete a Smart Folder.
    Rm(FolderRmArgs),
    /// Add a note to a Smart Folder, or change its membership pin.
    Add(FolderAddArgs),
    /// Remove a note from a Smart Folder.
    Remove(FolderRemoveArgs),
}

/// `memex folder ls --vault V`
#[derive(Args, Debug)]
pub struct FolderLsArgs {
    /// Vault directory.
    #[arg(long)]
    pub vault: PathBuf,
}

/// `memex folder new --vault V --name NAME [--parent-id P]`
#[derive(Args, Debug)]
pub struct FolderNewArgs {
    /// Vault directory.
    #[arg(long)]
    pub vault: PathBuf,
    /// Folder name.
    #[arg(long)]
    pub name: String,
    /// Parent folder id (default: a top-level folder).
    #[arg(long)]
    pub parent_id: Option<String>,
}

/// `memex folder update --vault V --id F [--name NAME]
/// [--parent-id P | --to-root] [--pinned true|false]`
#[derive(Args, Debug)]
pub struct FolderUpdateArgs {
    /// Vault directory.
    #[arg(long)]
    pub vault: PathBuf,
    /// Folder id.
    #[arg(long)]
    pub id: String,
    /// New name.
    #[arg(long)]
    pub name: Option<String>,
    /// New parent folder id.
    #[arg(long, conflicts_with = "to_root")]
    pub parent_id: Option<String>,
    /// Move the folder to the top level.
    #[arg(long)]
    pub to_root: bool,
    /// Pin or unpin the folder.
    #[arg(long, action = ArgAction::Set)]
    pub pinned: Option<bool>,
}

/// `memex folder rm --vault V --id F`
#[derive(Args, Debug)]
pub struct FolderRmArgs {
    /// Vault directory.
    #[arg(long)]
    pub vault: PathBuf,
    /// Folder id.
    #[arg(long)]
    pub id: String,
}

/// `memex folder add --vault V --id F --note-id N [--pinned true|false]`
#[derive(Args, Debug)]
pub struct FolderAddArgs {
    /// Vault directory.
    #[arg(long)]
    pub vault: PathBuf,
    /// Folder id.
    #[arg(long)]
    pub id: String,
    /// Note id (ULID).
    #[arg(long)]
    pub note_id: String,
    /// Pin the membership.
    #[arg(long, default_value_t = true, action = ArgAction::Set)]
    pub pinned: bool,
}

/// `memex folder remove --vault V --id F --note-id N`
#[derive(Args, Debug)]
pub struct FolderRemoveArgs {
    /// Vault directory.
    #[arg(long)]
    pub vault: PathBuf,
    /// Folder id.
    #[arg(long)]
    pub id: String,
    /// Note id (ULID).
    #[arg(long)]
    pub note_id: String,
}

pub fn run(args: FolderArgs) -> anyhow::Result<()> {
    match args.command {
        FolderCommand::Ls(_) => super::not_implemented("folder ls"),
        FolderCommand::New(_) => super::not_implemented("folder new"),
        FolderCommand::Update(_) => super::not_implemented("folder update"),
        FolderCommand::Rm(_) => super::not_implemented("folder rm"),
        FolderCommand::Add(_) => super::not_implemented("folder add"),
        FolderCommand::Remove(_) => super::not_implemented("folder remove"),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn vault() -> PathBuf {
        PathBuf::from("v")
    }

    #[test]
    fn stubs_report_not_implemented() {
        let cases = [
            (
                FolderCommand::Ls(FolderLsArgs { vault: vault() }),
                "folder ls",
            ),
            (
                FolderCommand::New(FolderNewArgs {
                    vault: vault(),
                    name: "Games".into(),
                    parent_id: None,
                }),
                "folder new",
            ),
            (
                FolderCommand::Update(FolderUpdateArgs {
                    vault: vault(),
                    id: "f".into(),
                    name: None,
                    parent_id: None,
                    to_root: false,
                    pinned: None,
                }),
                "folder update",
            ),
            (
                FolderCommand::Rm(FolderRmArgs {
                    vault: vault(),
                    id: "f".into(),
                }),
                "folder rm",
            ),
            (
                FolderCommand::Add(FolderAddArgs {
                    vault: vault(),
                    id: "f".into(),
                    note_id: "n".into(),
                    pinned: true,
                }),
                "folder add",
            ),
            (
                FolderCommand::Remove(FolderRemoveArgs {
                    vault: vault(),
                    id: "f".into(),
                    note_id: "n".into(),
                }),
                "folder remove",
            ),
        ];
        for (command, name) in cases {
            let err = run(FolderArgs { command }).unwrap_err();
            assert_eq!(
                err.to_string(),
                format!("memex {name}: not implemented yet")
            );
        }
    }
}
