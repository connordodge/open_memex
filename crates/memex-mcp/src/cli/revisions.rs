//! `memex revisions` (Spec #7 Req 27, 28, 37; rulings D11, D14): the earlier
//! person sections agent edits kept of a note.

use std::path::PathBuf;

use clap::{Args, Subcommand};
use memex_core::{SystemClock, Vault};

use crate::ops::note_edits;

/// `memex revisions <command>`
#[derive(Args, Debug)]
pub struct RevisionsArgs {
    #[command(subcommand)]
    pub command: RevisionsCommand,
}

#[derive(Subcommand, Debug)]
pub enum RevisionsCommand {
    /// List the note's agent-edit revisions, newest first.
    List(RevisionsListArgs),
    /// Return a note to the text an agent edit replaced, keeping the replaced one.
    Restore(RevisionsRestoreArgs),
}

/// `memex revisions list --vault V --note-id N`
#[derive(Args, Debug)]
pub struct RevisionsListArgs {
    /// Vault directory.
    #[arg(long)]
    pub vault: PathBuf,
    /// Note id (ULID).
    #[arg(long)]
    pub note_id: String,
}

/// `memex revisions restore --vault V --revision-id R`
#[derive(Args, Debug)]
pub struct RevisionsRestoreArgs {
    /// Vault directory.
    #[arg(long)]
    pub vault: PathBuf,
    /// The revision to return to.
    #[arg(long)]
    pub revision_id: String,
}

pub fn run(args: RevisionsArgs) -> anyhow::Result<()> {
    match args.command {
        RevisionsCommand::List(a) => list(a),
        RevisionsCommand::Restore(a) => restore(a),
    }
}

fn list(args: RevisionsListArgs) -> anyhow::Result<()> {
    let mut vault = Vault::open(&args.vault)?;
    let input = note_edits::NoteRevisionsInput {
        note_id: args.note_id,
    };
    let out = note_edits::note_revisions(&mut vault, input, &SystemClock, None)?;
    println!("{}", serde_json::to_string(&out)?);
    Ok(())
}

/// The CLI names no note, so the revision's own note is restored. Its
/// Activity entry is dated today in local time.
fn restore(args: RevisionsRestoreArgs) -> anyhow::Result<()> {
    let mut vault = Vault::open(&args.vault)?;
    let input = note_edits::RestoreNoteRevisionInput {
        revision_id: args.revision_id,
        note_id: None,
    };
    let out = note_edits::restore_note_revision(&mut vault, input, &SystemClock, None)?;
    println!("{}", serde_json::to_string(&out)?);
    Ok(())
}
