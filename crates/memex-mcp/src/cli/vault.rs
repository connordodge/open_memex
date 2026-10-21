//! `memex vault check --vault <path>`: is this folder safe for a vault
//! (req 30, 31; D4)?
//!
//! Exit 0 when the folder (or, for a path that doesn't exist yet, its
//! nearest existing ancestor) is on a local filesystem; one C1 line on stderr
//! and exit 1 when it is on a network filesystem (`network_filesystem`) or
//! the filesystem can't be read. It never creates anything and never opens
//! SQLite, so the app can run it before it touches `memex.db`. Exit 2 stays
//! clap's usage error (D19).

use std::io;
use std::path::{Path, PathBuf};

use anyhow::{Context, Result};
use clap::{Args, Subcommand};
use memex_core::fs_guard::{self, FsInfo};

#[derive(Args, Debug)]
pub struct VaultArgs {
    #[command(subcommand)]
    pub command: VaultCommand,
}

#[derive(Subcommand, Debug)]
pub enum VaultCommand {
    /// Exit 0 when <path> is safe for a vault (not on a network drive).
    Check {
        /// Vault directory (need not exist yet).
        #[arg(long)]
        vault: PathBuf,
    },
}

/// Runs the chosen `memex vault` subcommand.
pub fn run(args: VaultArgs) -> Result<()> {
    match args.command {
        VaultCommand::Check { vault } => check_with(&vault, &fs_guard::probe),
    }
}

/// `memex vault check` with the network-drive guard asking `probe` instead
/// of `statfs`. A relative `path` is made absolute first.
pub fn check_with(path: &Path, probe: &dyn Fn(&Path) -> io::Result<FsInfo>) -> Result<()> {
    let absolute = std::path::absolute(path).context("resolve --vault")?;
    fs_guard::check_with(&absolute, probe)?;
    Ok(())
}
