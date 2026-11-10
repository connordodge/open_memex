//! `memex backup --vault <path> --dest <dir> [--keep <n>] [--if-changed]`
//! (Spec #315 req 17, 17a; architecture D13).

use std::path::PathBuf;

use clap::Args;

// TODO(#316): skeleton. The flags, `--keep`'s range and default, and `run`
// land with the implementation (see the help golden `backup.txt`).
#[derive(Args, Debug)]
pub struct BackupArgs {
    #[arg(skip)]
    pub vault: PathBuf,
    #[arg(skip)]
    pub dest: PathBuf,
    #[arg(skip)]
    pub keep: u16,
    #[arg(skip)]
    pub if_changed: bool,
}
