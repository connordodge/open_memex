//! `memex filing` (#256): where the blocks of one day are filed.

use std::path::PathBuf;

use clap::Args;
use memex_core::{SystemClock, Vault};

use crate::ops::excerpt;

/// `memex filing --vault V --date YYYY-MM-DD`
#[derive(Args, Debug)]
pub struct FilingArgs {
    /// Vault directory.
    #[arg(long)]
    pub vault: PathBuf,
    /// The daily note's date, YYYY-MM-DD.
    #[arg(long)]
    pub date: String,
}

pub fn run(args: FilingArgs) -> anyhow::Result<()> {
    let mut vault = Vault::open(&args.vault)?;
    let input = excerpt::FilingInput { date: args.date };
    let out = excerpt::filing(&mut vault, input, &SystemClock, None)?;
    println!("{}", serde_json::to_string(&out)?);
    Ok(())
}
