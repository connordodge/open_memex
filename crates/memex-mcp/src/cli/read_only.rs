//! `memex read-only` (Spec #7 Req 37; rulings D5, D14): the person's Agent
//! read-only flag of a note.

use std::path::PathBuf;

use clap::{Args, Subcommand};
use memex_core::{SystemClock, Vault};

use crate::ops::note_edits;

/// `memex read-only <command>`
#[derive(Args, Debug)]
pub struct ReadOnlyArgs {
    #[command(subcommand)]
    pub command: ReadOnlyCommand,
}

#[derive(Subcommand, Debug)]
pub enum ReadOnlyCommand {
    /// Make the note read-only for agents.
    Set(ReadOnlyNoteArgs),
    /// Let agents edit the note again.
    Clear(ReadOnlyNoteArgs),
}

/// `memex read-only set|clear --vault V --note-id N`
#[derive(Args, Debug)]
pub struct ReadOnlyNoteArgs {
    /// Vault directory.
    #[arg(long)]
    pub vault: PathBuf,
    /// Note id (ULID).
    #[arg(long)]
    pub note_id: String,
}

pub fn run(args: ReadOnlyArgs) -> anyhow::Result<()> {
    match args.command {
        ReadOnlyCommand::Set(a) => set(a, true),
        ReadOnlyCommand::Clear(a) => set(a, false),
    }
}

fn set(args: ReadOnlyNoteArgs, on: bool) -> anyhow::Result<()> {
    let mut vault = Vault::open(&args.vault)?;
    let input = note_edits::SetAgentReadOnlyInput {
        note_id: args.note_id,
        agent_read_only: on,
    };
    let out = note_edits::set_agent_read_only(&mut vault, input, &SystemClock, None)?;
    println!("{}", serde_json::to_string(&out)?);
    Ok(())
}
