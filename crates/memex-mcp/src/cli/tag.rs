//! `memex tag` (Spec #234 R45): add, remove and list tags, one JSON line on
//! stdout.

use std::path::PathBuf;

use clap::{Args, Subcommand};
use memex_core::{NoteId, SystemClock, Vault};

use crate::ops::tags;

/// `memex tag <command>`
#[derive(Args, Debug)]
pub struct TagArgs {
    #[command(subcommand)]
    pub command: TagCommand,
}

#[derive(Subcommand, Debug)]
pub enum TagCommand {
    /// Add a tag to a note, in its footer.
    Add(TagWriteArgs),
    /// Remove a tag from a note.
    Rm(TagWriteArgs),
    /// List every tag, or one note's tags.
    Ls(TagLsArgs),
}

/// `memex tag add|rm --vault V --note-id N --tag T`
#[derive(Args, Debug)]
pub struct TagWriteArgs {
    /// Vault directory.
    #[arg(long)]
    pub vault: PathBuf,
    /// Note id (ULID).
    #[arg(long)]
    pub note_id: String,
    /// Tag name.
    #[arg(long)]
    pub tag: String,
}

/// `memex tag ls --vault V [--note-id N]`
#[derive(Args, Debug)]
pub struct TagLsArgs {
    /// Vault directory.
    #[arg(long)]
    pub vault: PathBuf,
    /// List this note's tags and their origins (ULID).
    #[arg(long)]
    pub note_id: Option<String>,
}

pub fn run(args: TagArgs) -> anyhow::Result<()> {
    let line = match args.command {
        TagCommand::Add(a) => {
            NoteId::parse(&a.note_id)?;
            let input = tags::AddInput {
                note_id: a.note_id,
                tag: a.tag,
            };
            let mut vault = Vault::open(&a.vault)?;
            serde_json::to_string(&tags::add(&mut vault, input, &SystemClock, None)?)?
        }
        TagCommand::Rm(a) => {
            NoteId::parse(&a.note_id)?;
            let input = tags::RmInput {
                note_id: a.note_id,
                tag: a.tag,
            };
            let mut vault = Vault::open(&a.vault)?;
            serde_json::to_string(&tags::rm(&mut vault, input, &SystemClock, None)?)?
        }
        TagCommand::Ls(a) => match a.note_id {
            Some(note_id) => {
                NoteId::parse(&note_id)?;
                let input = tags::LsNoteInput { note_id };
                let mut vault = Vault::open(&a.vault)?;
                serde_json::to_string(&tags::ls_note(&mut vault, input, &SystemClock, None)?)?
            }
            None => {
                let mut vault = Vault::open(&a.vault)?;
                let out = tags::ls(&mut vault, tags::LsInput, &SystemClock, None)?;
                serde_json::to_string(&out)?
            }
        },
    };
    println!("{line}");
    Ok(())
}
