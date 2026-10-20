//! `memex footer` (CONTRACTS C2.3): manage a daily note's topic footer.

use std::path::PathBuf;

use clap::{Args, Subcommand};
use memex_core::{NoteId, SystemClock, Vault};

use crate::ops::footer;

/// `memex footer <command>`
#[derive(Args, Debug)]
pub struct FooterArgs {
    #[command(subcommand)]
    pub command: FooterCommand,
}

#[derive(Subcommand, Debug)]
pub enum FooterCommand {
    /// Add a topic to a daily note's footer.
    Add(FooterAddArgs),
}

/// `memex footer add --vault V --daily-note-id D --topic-note-id T`
#[derive(Args, Debug)]
pub struct FooterAddArgs {
    /// Vault directory.
    #[arg(long)]
    pub vault: PathBuf,
    /// Daily note id (ULID).
    #[arg(long)]
    pub daily_note_id: String,
    /// Topic note id (ULID).
    #[arg(long)]
    pub topic_note_id: String,
}

pub fn run(args: FooterArgs) -> anyhow::Result<()> {
    match args.command {
        FooterCommand::Add(a) => add(a),
    }
}

/// `memex footer add`: records a `person` chip (Req 17). Idempotent; an
/// `excerpt` chip is upgraded in place.
fn add(args: FooterAddArgs) -> anyhow::Result<()> {
    NoteId::parse(&args.daily_note_id)?;
    NoteId::parse(&args.topic_note_id)?;
    let mut vault = Vault::open(&args.vault)?;
    let input = footer::AddInput {
        daily_note_id: args.daily_note_id,
        topic_note_id: args.topic_note_id,
    };
    let out = footer::add(&mut vault, input, &SystemClock, None)?;
    println!("{}", serde_json::to_string(&out)?);
    Ok(())
}
