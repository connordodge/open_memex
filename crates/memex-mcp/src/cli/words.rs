//! `memex words` (Spec #392 requirement 16): list, learn and forget learned
//! words, one JSON line on stdout.

use std::path::PathBuf;

use clap::{Args, Subcommand};
use memex_core::{SystemClock, Vault};

use crate::ops::words;

/// `memex words <command>`
#[derive(Args, Debug)]
pub struct WordsArgs {
    #[command(subcommand)]
    pub command: WordsCommand,
}

#[derive(Subcommand, Debug)]
pub enum WordsCommand {
    /// List the learned words, sorted.
    Ls(WordsLsArgs),
    /// Learn a word, so spell check accepts it in this vault.
    Add(WordsWriteArgs),
    /// Forget a learned word, in any capitalisation.
    Rm(WordsWriteArgs),
}

/// `memex words ls --vault V`
#[derive(Args, Debug)]
pub struct WordsLsArgs {
    /// Vault directory.
    #[arg(long)]
    pub vault: PathBuf,
}

/// `memex words add|rm --vault V --word W`
#[derive(Args, Debug)]
pub struct WordsWriteArgs {
    /// Vault directory.
    #[arg(long)]
    pub vault: PathBuf,
    /// Word (trimmed; no whitespace, at most 64 characters).
    #[arg(long)]
    pub word: String,
}

pub fn run(args: WordsArgs) -> anyhow::Result<()> {
    let line = match args.command {
        WordsCommand::Ls(a) => {
            let mut vault = Vault::open(&a.vault)?;
            serde_json::to_string(&words::ls(&mut vault, words::LsInput, &SystemClock, None)?)?
        }
        WordsCommand::Add(a) => {
            let mut vault = Vault::open(&a.vault)?;
            let input = words::AddInput { word: a.word };
            serde_json::to_string(&words::add(&mut vault, input, &SystemClock, None)?)?
        }
        WordsCommand::Rm(a) => {
            let mut vault = Vault::open(&a.vault)?;
            let input = words::RmInput { word: a.word };
            serde_json::to_string(&words::rm(&mut vault, input, &SystemClock, None)?)?
        }
    };
    println!("{line}");
    Ok(())
}
