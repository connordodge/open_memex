//! `memex append` (CONTRACTS C2.12): append text to a daily note.

use std::io::Read;
use std::path::PathBuf;

use anyhow::Context;
use clap::Args;
use memex_core::canvas::SystemClock;
use memex_core::daily::{self, AppendSource};
use memex_core::Vault;

use super::InvalidArgument;
use crate::tools::daily::Appended;

/// `memex append --vault V [--date YYYY-MM-DD] [TEXT]` (stdin when TEXT is
/// absent).
#[derive(Args, Debug)]
pub struct AppendArgs {
    /// Vault directory.
    #[arg(long)]
    pub vault: PathBuf,
    /// Daily note date, YYYY-MM-DD (default: today, local time).
    #[arg(long)]
    pub date: Option<String>,
    /// Text to append (read from stdin when omitted).
    pub text: Option<String>,
}

/// Quick entry: the person's text lands as `quick-entry` blocks, unfiled (no
/// footer chip, no excerpt), on the day's daily note in local time.
pub fn run(args: AppendArgs) -> anyhow::Result<()> {
    let text = match args.text {
        Some(text) => text,
        None => {
            let mut buf = String::new();
            std::io::stdin()
                .read_to_string(&mut buf)
                .context("read text from stdin")?;
            buf
        }
    };
    if text.trim().is_empty() {
        let msg = "nothing to append: TEXT and stdin are empty".to_string();
        return Err(InvalidArgument(msg).into());
    }

    let mut vault = Vault::open(&args.vault).context("open vault")?;
    let outcome = daily::append_to_daily_note(
        &mut vault,
        &text,
        args.date.as_deref(),
        AppendSource::QuickEntry,
        &SystemClock,
        None,
    )?;
    let line = Appended::new(vault.vault_id(), &outcome);
    println!("{}", serde_json::to_string(&line)?);
    Ok(())
}
