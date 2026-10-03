//! `memex rm` (CONTRACTS C2.2): delete a note with optimistic concurrency.

use std::path::PathBuf;

use clap::Args;
use memex_core::notes::delete_note_checked;
use memex_core::{NoteId, Vault};
use serde::Serialize;

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

/// The C2.2 output line.
#[derive(Serialize)]
struct Removed<'a> {
    vault_id: &'a str,
    note_id: &'a str,
    deleted: bool,
}

/// `memex rm`: the person-only delete (Req 76, D24).
pub fn run(args: RmArgs) -> anyhow::Result<()> {
    let id = NoteId::parse(&args.note_id)?;
    let mut vault = Vault::open(&args.vault)?;
    delete_note_checked(&mut vault, &id, args.expected_version, None)?;
    let out = Removed {
        vault_id: vault.vault_id(),
        note_id: id.as_str(),
        deleted: true,
    };
    println!("{}", serde_json::to_string(&out)?);
    Ok(())
}
