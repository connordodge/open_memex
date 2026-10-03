//! `memex footer` (CONTRACTS C2.3): manage a daily note's topic footer.

use std::path::PathBuf;

use clap::{Args, Subcommand};
use memex_core::footer::{self, ChipOrigin};
use memex_core::{NoteId, Vault};
use serde::Serialize;

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

/// The C2.3 output line.
#[derive(Serialize)]
struct FooterAdded<'a> {
    vault_id: &'a str,
    daily_note_id: &'a str,
    topic_note_id: &'a str,
    origin: &'static str,
    /// The daily note's `notes.version` after the call.
    version: i64,
}

pub fn run(args: FooterArgs) -> anyhow::Result<()> {
    match args.command {
        FooterCommand::Add(a) => add(a),
    }
}

/// `memex footer add`: records a `person` chip (Req 17). Idempotent; an
/// `excerpt` chip is upgraded in place.
fn add(args: FooterAddArgs) -> anyhow::Result<()> {
    let daily = NoteId::parse(&args.daily_note_id)?;
    let topic = NoteId::parse(&args.topic_note_id)?;
    let mut vault = Vault::open(&args.vault)?;
    let written = footer::set_chip(&mut vault, &daily, &topic, ChipOrigin::Person, None)?;
    let origin = written.origin.unwrap_or(ChipOrigin::Person);
    let out = FooterAdded {
        vault_id: vault.vault_id(),
        daily_note_id: daily.as_str(),
        topic_note_id: topic.as_str(),
        origin: origin.as_str(),
        version: written.note.version,
    };
    println!("{}", serde_json::to_string(&out)?);
    Ok(())
}
