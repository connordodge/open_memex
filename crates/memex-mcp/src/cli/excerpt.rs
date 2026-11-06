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
    /// File one block of a day in a topic note.
    Add(ExcerptAddArgs),
    /// Remove one block of a day from a topic note.
    RemoveBlock(ExcerptRemoveBlockArgs),
    /// Move one block of a day from one topic note to another.
    Move(ExcerptMoveArgs),
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

/// `memex excerpt add --vault V --topic-note-id T --date YYYY-MM-DD
/// --block-id B [--note TEXT]`
#[derive(Args, Debug)]
pub struct ExcerptAddArgs {
    /// Vault directory.
    #[arg(long)]
    pub vault: PathBuf,
    /// Topic note id (ULID).
    #[arg(long)]
    pub topic_note_id: String,
    /// The daily note's date, YYYY-MM-DD.
    #[arg(long)]
    pub date: String,
    /// The block's id.
    #[arg(long)]
    pub block_id: String,
    /// Why the block belongs here, stored on the Correction.
    #[arg(long, allow_hyphen_values = true)]
    pub note: Option<String>,
}

/// `memex excerpt remove-block --vault V --topic-note-id T --date YYYY-MM-DD
/// --block-id B [--note TEXT]`
#[derive(Args, Debug)]
pub struct ExcerptRemoveBlockArgs {
    /// Vault directory.
    #[arg(long)]
    pub vault: PathBuf,
    /// Topic note id (ULID).
    #[arg(long)]
    pub topic_note_id: String,
    /// The daily note's date, YYYY-MM-DD.
    #[arg(long)]
    pub date: String,
    /// The block's id.
    #[arg(long)]
    pub block_id: String,
    /// Why the block doesn't belong here, stored on the Correction.
    #[arg(long, allow_hyphen_values = true)]
    pub note: Option<String>,
}

/// `memex excerpt move --vault V --date YYYY-MM-DD --block-id B
/// --from-topic-note-id A --to-topic-note-id C [--note TEXT]`
#[derive(Args, Debug)]
pub struct ExcerptMoveArgs {
    /// Vault directory.
    #[arg(long)]
    pub vault: PathBuf,
    /// The daily note's date, YYYY-MM-DD.
    #[arg(long)]
    pub date: String,
    /// The block's id.
    #[arg(long)]
    pub block_id: String,
    /// The topic note the block moves from (ULID).
    #[arg(long)]
    pub from_topic_note_id: String,
    /// The topic note the block moves to (ULID).
    #[arg(long)]
    pub to_topic_note_id: String,
    /// Why the block belongs there, stored on the Correction.
    #[arg(long, allow_hyphen_values = true)]
    pub note: Option<String>,
}

pub fn run(args: ExcerptArgs) -> anyhow::Result<()> {
    match args.command {
        ExcerptCommand::Rm(a) => rm(a),
        ExcerptCommand::Add(a) => add(a),
        ExcerptCommand::RemoveBlock(a) => remove_block(a),
        ExcerptCommand::Move(a) => move_block(a),
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

/// `memex excerpt add`: the person files one block and records a Correction.
fn add(args: ExcerptAddArgs) -> anyhow::Result<()> {
    let input = excerpt::AddInput {
        topic_note_id: args.topic_note_id,
        date: args.date,
        block_id: args.block_id,
        note: args.note,
    };
    input.validate()?;
    let mut vault = Vault::open(&args.vault)?;
    let out = excerpt::add(&mut vault, input, &SystemClock, None)?;
    println!("{}", serde_json::to_string(&out)?);
    Ok(())
}

/// `memex excerpt remove-block`: the person removes one block, splitting a
/// range that covers it, and records a Correction.
fn remove_block(args: ExcerptRemoveBlockArgs) -> anyhow::Result<()> {
    let input = excerpt::RemoveBlockInput {
        topic_note_id: args.topic_note_id,
        date: args.date,
        block_id: args.block_id,
        note: args.note,
    };
    input.validate()?;
    let mut vault = Vault::open(&args.vault)?;
    let out = excerpt::remove_block(&mut vault, input, &SystemClock, None)?;
    println!("{}", serde_json::to_string(&out)?);
    Ok(())
}

/// `memex excerpt move`: the person moves one block and records one Correction.
fn move_block(args: ExcerptMoveArgs) -> anyhow::Result<()> {
    let input = excerpt::MoveInput {
        date: args.date,
        block_id: args.block_id,
        from_topic_note_id: args.from_topic_note_id,
        to_topic_note_id: args.to_topic_note_id,
        note: args.note,
    };
    input.validate()?;
    let mut vault = Vault::open(&args.vault)?;
    let out = excerpt::move_block(&mut vault, input, &SystemClock, None)?;
    println!("{}", serde_json::to_string(&out)?);
    Ok(())
}
