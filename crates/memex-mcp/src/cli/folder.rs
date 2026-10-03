//! `memex folder` (CONTRACTS C2.5–C2.10): Smart Folders and their members.

use std::path::PathBuf;

use clap::{ArgAction, Args, Subcommand};
use memex_core::canvas::SystemClock;
use memex_core::smart_folders::{self as sf, FolderUpdate, NewParent};
use memex_core::{Caller, Vault};
use serde::Serialize;

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

/// `vault_id` first on the wire, then the core object's own fields.
#[derive(Serialize)]
struct WithVault<'a, T: Serialize> {
    vault_id: &'a str,
    #[serde(flatten)]
    body: T,
}

#[derive(Serialize)]
struct Deleted<'a> {
    id: &'a str,
    deleted: bool,
}

#[derive(Serialize)]
struct Removed<'a> {
    smart_folder_id: &'a str,
    note_id: &'a str,
    removed: bool,
}

/// One JSON line on stdout.
fn print_json<T: Serialize>(vault: &Vault, body: T) -> anyhow::Result<()> {
    let out = WithVault {
        vault_id: vault.vault_id(),
        body,
    };
    println!("{}", serde_json::to_string(&out)?);
    Ok(())
}

pub fn run(args: FolderArgs) -> anyhow::Result<()> {
    // The person's CLI: `Caller::Person` and the wall clock.
    let clock = SystemClock;
    match args.command {
        FolderCommand::Ls(a) => {
            let vault = Vault::open(&a.vault)?;
            print_json(&vault, sf::list_folders(&vault)?)
        }
        FolderCommand::New(a) => {
            let mut vault = Vault::open(&a.vault)?;
            let folder = sf::create_folder(
                &mut vault,
                &a.name,
                a.parent_id.as_deref(),
                Caller::Person,
                &clock,
            )?;
            print_json(&vault, folder)
        }
        FolderCommand::Update(a) => {
            let mut vault = Vault::open(&a.vault)?;
            let parent = if a.to_root {
                Some(NewParent::Root)
            } else {
                a.parent_id.map(NewParent::Folder)
            };
            let update = FolderUpdate {
                name: a.name,
                parent,
                pinned: a.pinned,
            };
            let folder = sf::update_folder(&mut vault, &a.id, update, Caller::Person, &clock)?;
            print_json(&vault, folder)
        }
        FolderCommand::Rm(a) => {
            let mut vault = Vault::open(&a.vault)?;
            sf::delete_folder(&mut vault, &a.id, Caller::Person)?;
            print_json(
                &vault,
                Deleted {
                    id: &a.id,
                    deleted: true,
                },
            )
        }
        FolderCommand::Add(a) => {
            let mut vault = Vault::open(&a.vault)?;
            let membership = sf::add_member(
                &mut vault,
                &a.id,
                &a.note_id,
                Some(a.pinned),
                Caller::Person,
                None,
            )?;
            print_json(&vault, membership)
        }
        FolderCommand::Remove(a) => {
            let mut vault = Vault::open(&a.vault)?;
            sf::remove_member(&mut vault, &a.id, &a.note_id, Caller::Person)?;
            print_json(
                &vault,
                Removed {
                    smart_folder_id: &a.id,
                    note_id: &a.note_id,
                    removed: true,
                },
            )
        }
    }
}
