//! `memex excerpt` (CONTRACTS C2.4): manage a topic note's excerpts.

use std::path::PathBuf;

use clap::{Args, Subcommand};
use memex_core::excerpts;
use memex_core::{Caller, NoteId, Vault};

use super::InvalidArgument;
use crate::tools::excerpts::ExcerptWritten;

/// `memex excerpt <command>`
#[derive(Args, Debug)]
pub struct ExcerptArgs {
    #[command(subcommand)]
    pub command: ExcerptCommand,
}

#[derive(Subcommand, Debug)]
pub enum ExcerptCommand {
    /// Remove one transclusion from a topic note.
    Rm(ExcerptRmArgs),
}

/// `memex excerpt rm --vault V --topic-note-id T --date YYYY-MM-DD
/// --block-ids b7k2m9[,c3d4e5]`
#[derive(Args, Debug)]
pub struct ExcerptRmArgs {
    /// Vault directory.
    #[arg(long)]
    pub vault: PathBuf,
    /// Topic note id (ULID).
    #[arg(long)]
    pub topic_note_id: String,
    /// The daily note's date, YYYY-MM-DD.
    #[arg(long)]
    pub date: String,
    /// The transclusion's endpoint block ids: one id, or `from,to` for a range.
    #[arg(long, value_delimiter = ',', required = true)]
    pub block_ids: Vec<String>,
}

pub fn run(args: ExcerptArgs) -> anyhow::Result<()> {
    match args.command {
        ExcerptCommand::Rm(a) => rm(a),
    }
}

/// `memex excerpt rm`: the person removes one transclusion (Req 14). The
/// topic's `excerpt` chip on that day goes with its last excerpt from it.
fn rm(args: ExcerptRmArgs) -> anyhow::Result<()> {
    if args.block_ids.iter().any(|id| id.trim().is_empty()) {
        let msg = "--block-ids must list one or two non-empty block ids".to_string();
        return Err(InvalidArgument(msg).into());
    }
    let topic = NoteId::parse(&args.topic_note_id)?;
    let mut vault = Vault::open(&args.vault)?;
    let written = excerpts::remove_excerpt(
        &mut vault,
        &topic,
        &args.date,
        &args.block_ids,
        Caller::Person,
        None,
    )?;
    let line = ExcerptWritten::new(&vault, &written);
    println!("{}", serde_json::to_string(&line)?);
    Ok(())
}
