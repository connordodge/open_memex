//! `memex excerpt` (CONTRACTS C2.4): manage a topic note's excerpts.

use std::path::PathBuf;

use clap::{Args, Subcommand};
use memex_core::{SystemClock, Vault};

use crate::ops::excerpt;

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
    let input = excerpt::RmInput {
        topic_note_id: args.topic_note_id,
        date: args.date,
        block_ids: args.block_ids,
    };
    input.validate()?;
    let mut vault = Vault::open(&args.vault)?;
    let out = excerpt::rm(&mut vault, input, &SystemClock, None)?;
    println!("{}", serde_json::to_string(&out)?);
    Ok(())
}
