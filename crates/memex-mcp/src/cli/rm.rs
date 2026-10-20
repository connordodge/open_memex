//! `memex rm` (CONTRACTS C2.2): delete a note with optimistic concurrency.

use std::path::PathBuf;

use clap::Args;
use memex_core::{NoteId, SystemClock, Vault};

use crate::ops::notes::{self, RmInput};

/// `memex rm --vault V --note-id ID --expected-version N`
#[derive(Args, Debug)]
pub struct RmArgs {
    /// Vault directory.
    #[arg(long)]
    pub vault: PathBuf,
    /// Note id (ULID).
    #[arg(long)]
    pub note_id: String,
    /// Expected current version (optimistic concurrency).
    #[arg(long)]
    pub expected_version: i64,
}

/// `memex rm`: the person-only delete (Req 76, D24).
pub fn run(args: RmArgs) -> anyhow::Result<()> {
    NoteId::parse(&args.note_id)?;
    let mut vault = Vault::open(&args.vault)?;
    let input = RmInput {
        note_id: args.note_id,
        expected_version: args.expected_version,
    };
    let out = notes::rm(&mut vault, input, &SystemClock, None)?;
    println!("{}", serde_json::to_string(&out)?);
    Ok(())
}
