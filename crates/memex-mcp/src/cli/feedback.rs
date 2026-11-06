//! `memex feedback` (#256): the person's written comments, and every row's
//! listing.

use std::path::PathBuf;

use clap::{ArgGroup, Args, Subcommand};
use memex_core::{SystemClock, Vault};

use crate::ops::feedback;

/// `memex feedback <command>`
#[derive(Args, Debug)]
pub struct FeedbackArgs {
    #[command(subcommand)]
    pub command: FeedbackCommand,
}

#[derive(Subcommand, Debug)]
pub enum FeedbackCommand {
    /// Add a comment on an Activity entry.
    Add(FeedbackAddArgs),
    /// Replace the text of an Open comment.
    Edit(FeedbackEditArgs),
    /// Delete an Open comment.
    Rm(FeedbackRmArgs),
    /// List one note's rows, or the rows with no note, newest first.
    Ls(FeedbackLsArgs),
}

/// `memex feedback add --vault V --note-id N --date YYYY-MM-DD --change-id C
/// --text TEXT`
#[derive(Args, Debug)]
pub struct FeedbackAddArgs {
    /// Vault directory.
    #[arg(long)]
    pub vault: PathBuf,
    /// The note the comment is on (ULID).
    #[arg(long)]
    pub note_id: String,
    /// The day the comment is about, YYYY-MM-DD.
    #[arg(long)]
    pub date: String,
    /// The Activity entry the comment is on.
    #[arg(long)]
    pub change_id: String,
    /// The comment, stored as given.
    #[arg(long, allow_hyphen_values = true)]
    pub text: String,
}

/// `memex feedback edit --vault V --id F --text TEXT`
#[derive(Args, Debug)]
pub struct FeedbackEditArgs {
    /// Vault directory.
    #[arg(long)]
    pub vault: PathBuf,
    /// The comment's id.
    #[arg(long)]
    pub id: String,
    /// The new text, stored as given.
    #[arg(long, allow_hyphen_values = true)]
    pub text: String,
}

/// `memex feedback rm --vault V --id F`
#[derive(Args, Debug)]
pub struct FeedbackRmArgs {
    /// Vault directory.
    #[arg(long)]
    pub vault: PathBuf,
    /// The comment's id.
    #[arg(long)]
    pub id: String,
}

/// `memex feedback ls --vault V (--note-id N | --no-note)`
#[derive(Args, Debug)]
#[command(group(ArgGroup::new("rows").required(true).args(["note_id", "no_note"])))]
pub struct FeedbackLsArgs {
    /// Vault directory.
    #[arg(long)]
    pub vault: PathBuf,
    /// List this note's rows.
    #[arg(long)]
    pub note_id: Option<String>,
    /// List the rows with no note.
    #[arg(long)]
    pub no_note: bool,
}

pub fn run(args: FeedbackArgs) -> anyhow::Result<()> {
    match args.command {
        FeedbackCommand::Add(a) => add(a),
        FeedbackCommand::Edit(a) => edit(a),
        FeedbackCommand::Rm(a) => rm(a),
        FeedbackCommand::Ls(a) => ls(a),
    }
}

fn add(args: FeedbackAddArgs) -> anyhow::Result<()> {
    let mut vault = Vault::open(&args.vault)?;
    let input = feedback::AddInput {
        note_id: args.note_id,
        date: args.date,
        change_id: args.change_id,
        text: args.text,
    };
    let out = feedback::add(&mut vault, input, &SystemClock, None)?;
    println!("{}", serde_json::to_string(&out)?);
    Ok(())
}

fn edit(args: FeedbackEditArgs) -> anyhow::Result<()> {
    let mut vault = Vault::open(&args.vault)?;
    let input = feedback::EditInput {
        id: args.id,
        text: args.text,
    };
    let out = feedback::edit(&mut vault, input, &SystemClock, None)?;
    println!("{}", serde_json::to_string(&out)?);
    Ok(())
}

fn rm(args: FeedbackRmArgs) -> anyhow::Result<()> {
    let mut vault = Vault::open(&args.vault)?;
    let input = feedback::RmInput { id: args.id };
    let out = feedback::rm(&mut vault, input, &SystemClock, None)?;
    println!("{}", serde_json::to_string(&out)?);
    Ok(())
}

fn ls(args: FeedbackLsArgs) -> anyhow::Result<()> {
    let input = feedback::LsInput {
        note_id: args.note_id,
    };
    input.validate()?;
    let mut vault = Vault::open(&args.vault)?;
    let out = feedback::ls(&mut vault, input, &SystemClock, None)?;
    println!("{}", serde_json::to_string(&out)?);
    Ok(())
}
