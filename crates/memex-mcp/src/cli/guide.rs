//! `memex guide` (#256): the Vault Guide on the person's channel.

use std::path::PathBuf;

use clap::{Args, Subcommand};
use memex_core::{SystemClock, Vault};

use crate::ops::guide;

/// `memex guide <command>`
#[derive(Args, Debug)]
pub struct GuideArgs {
    #[command(subcommand)]
    pub command: GuideCommand,
}

#[derive(Subcommand, Debug)]
pub enum GuideCommand {
    /// Print the guide, creating it on the first call.
    Get(GuideGetArgs),
    /// List the guide's kept earlier texts, newest first.
    Revisions(GuideRevisionsArgs),
    /// Return the guide to an earlier text, keeping the replaced one.
    Restore(GuideRestoreArgs),
}

/// `memex guide get --vault V`
#[derive(Args, Debug)]
pub struct GuideGetArgs {
    /// Vault directory.
    #[arg(long)]
    pub vault: PathBuf,
}

/// `memex guide revisions --vault V`
#[derive(Args, Debug)]
pub struct GuideRevisionsArgs {
    /// Vault directory.
    #[arg(long)]
    pub vault: PathBuf,
}

/// `memex guide restore --vault V --revision-id R`
#[derive(Args, Debug)]
pub struct GuideRestoreArgs {
    /// Vault directory.
    #[arg(long)]
    pub vault: PathBuf,
    /// The revision to return to.
    #[arg(long)]
    pub revision_id: String,
}

pub fn run(args: GuideArgs) -> anyhow::Result<()> {
    match args.command {
        GuideCommand::Get(a) => get(a),
        GuideCommand::Revisions(a) => revisions(a),
        GuideCommand::Restore(a) => restore(a),
    }
}

fn get(args: GuideGetArgs) -> anyhow::Result<()> {
    let mut vault = Vault::open(&args.vault)?;
    let out = guide::get(&mut vault, guide::GetInput, &SystemClock, None)?;
    println!("{}", serde_json::to_string(&out)?);
    Ok(())
}

fn revisions(args: GuideRevisionsArgs) -> anyhow::Result<()> {
    let mut vault = Vault::open(&args.vault)?;
    let out = guide::revisions(&mut vault, guide::RevisionsInput, &SystemClock, None)?;
    println!("{}", serde_json::to_string(&out)?);
    Ok(())
}

fn restore(args: GuideRestoreArgs) -> anyhow::Result<()> {
    let mut vault = Vault::open(&args.vault)?;
    let input = guide::RestoreInput {
        revision_id: args.revision_id,
    };
    let out = guide::restore(&mut vault, input, &SystemClock, None)?;
    println!("{}", serde_json::to_string(&out)?);
    Ok(())
}
