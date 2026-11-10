//! `memex backup --vault <path> --dest <dir> [--keep <n>] [--if-changed]`
//! (Spec #315 req 17, 17a; architecture D13).

use std::path::PathBuf;

use clap::Args;
use memex_core::backup::{self, BackupRequest, BackupSource, KEEP_DEFAULT};

/// `memex backup --vault V --dest D [--keep N] [--if-changed]`
#[derive(Args, Debug)]
pub struct BackupArgs {
    /// Vault directory.
    #[arg(long)]
    pub vault: PathBuf,
    /// Destination folder (must already exist).
    #[arg(long)]
    pub dest: PathBuf,
    /// How many backups of this vault the destination keeps (1-365).
    #[arg(long, default_value_t = KEEP_DEFAULT, value_parser = clap::value_parser!(u16).range(1..=365))]
    pub keep: u16,
    /// Skip writing a backup when the vault is unchanged since the last backup to this destination.
    #[arg(long)]
    pub if_changed: bool,
}

/// One backup; prints the req 17 line after every effect is done.
pub fn run(args: BackupArgs) -> anyhow::Result<()> {
    let outcome = backup::backup(&BackupRequest {
        vault: &args.vault,
        destination: &args.dest,
        keep: args.keep,
        if_changed: args.if_changed,
        source: BackupSource::Local,
    })?;
    super::write_json_line(&mut std::io::stdout().lock(), &outcome.to_json())
}
