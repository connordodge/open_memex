//! `memex restore --from <file> --to <folder>` (Spec #315 req 32-34;
//! architecture D13).

use std::path::PathBuf;

use clap::Args;
use memex_core::backup::{self, RestoreRequest};

/// `memex restore --from F --to T`
#[derive(Args, Debug)]
pub struct RestoreArgs {
    /// Backup file (`.memex.zip`).
    #[arg(long)]
    pub from: PathBuf,
    /// New vault folder (must not exist, or be an empty folder).
    #[arg(long)]
    pub to: PathBuf,
}

/// One restore; prints the req 34 line after every effect is done.
pub fn run(args: RestoreArgs) -> anyhow::Result<()> {
    let outcome = backup::restore(&RestoreRequest {
        from: &args.from,
        to: &args.to,
    })?;
    super::write_json_line(&mut std::io::stdout().lock(), &outcome.to_json())
}
