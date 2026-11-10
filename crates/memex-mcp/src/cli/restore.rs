//! `memex restore --from <file> --to <folder>` (Spec #315 req 32-34;
//! architecture D13).

use std::path::PathBuf;

use clap::Args;

// TODO(#316): skeleton. The flags and `run` land with the implementation
// (see the help golden `restore.txt`).
#[derive(Args, Debug)]
pub struct RestoreArgs {
    #[arg(skip)]
    pub from: PathBuf,
    #[arg(skip)]
    pub to: PathBuf,
}
