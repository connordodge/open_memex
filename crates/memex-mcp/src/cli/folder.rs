//! `memex folder` (CONTRACTS C2.5–C2.10): Smart Folders and their members.

use std::path::PathBuf;

use clap::{ArgAction, Args, Subcommand};
use memex_core::canvas::SystemClock;
use memex_core::Vault;
use serde::Serialize;

use crate::ops::folder;

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

/// One JSON line on stdout.
fn print_json<T: Serialize>(out: &T) -> anyhow::Result<()> {
    println!("{}", serde_json::to_string(out)?);
    Ok(())
}

pub fn run(args: FolderArgs) -> anyhow::Result<()> {
    // The person's CLI: `Caller::Person` (inside the ops) and the wall clock.
    let clock = SystemClock;
    match args.command {
        FolderCommand::Ls(a) => {
            let mut vault = Vault::open(&a.vault)?;
            print_json(&folder::ls(&mut vault, folder::LsInput, &clock, None)?)
        }
        FolderCommand::New(a) => {
            let mut vault = Vault::open(&a.vault)?;
            let input = folder::NewInput {
                name: a.name,
                parent_id: a.parent_id,
            };
            print_json(&folder::new(&mut vault, input, &clock, None)?)
        }
        FolderCommand::Update(a) => {
            let mut vault = Vault::open(&a.vault)?;
            let input = folder::UpdateInput {
                id: a.id,
                name: a.name,
                parent_id: a.parent_id,
                to_root: a.to_root,
                pinned: a.pinned,
            };
            print_json(&folder::update(&mut vault, input, &clock, None)?)
        }
        FolderCommand::Rm(a) => {
            let mut vault = Vault::open(&a.vault)?;
            let input = folder::RmInput { id: a.id };
            print_json(&folder::rm(&mut vault, input, &clock, None)?)
        }
        FolderCommand::Add(a) => {
            let mut vault = Vault::open(&a.vault)?;
            let input = folder::AddInput {
                id: a.id,
                note_id: a.note_id,
                pinned: a.pinned,
            };
            print_json(&folder::add(&mut vault, input, &clock, None)?)
        }
        FolderCommand::Remove(a) => {
            let mut vault = Vault::open(&a.vault)?;
            let input = folder::RemoveInput {
                id: a.id,
                note_id: a.note_id,
            };
            print_json(&folder::remove(&mut vault, input, &clock, None)?)
        }
    }
}
