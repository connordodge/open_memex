//! `memex attach --vault <path> <file> [--name <name>]` (Spec #123 R16):
//! stores one file in the vault's `objects/` folder through
//! `memex_core::attachments` and prints one JSON line `{markdown, path,
//! name, size, type}`. No note changes. Before it prints, the file's text
//! is extracted in this process and indexed (R17, #136).
//!
//! This is the person's channel: a symlink attaches the file it points to,
//! and there is no hidden-path limit (that is the MCP tool's, R19). A
//! refused file (R15: over 100 MB, a folder, a non-regular file) exits 1
//! with the C1 `invalid_argument` object whose message is the R15 text.

use std::io::ErrorKind;
use std::path::{Path, PathBuf};

use clap::Args;
use memex_core::attachments::{self, StoredAttachment};
use memex_core::attachments_extract;
use memex_core::{now_unix_ms, MemexError, Vault};

use super::{write_json_line, InvalidArgument};

/// `memex attach --vault V <file> [--name N]`
#[derive(Args, Debug)]
pub struct AttachArgs {
    /// Vault directory.
    #[arg(long)]
    pub vault: PathBuf,
    /// The file to attach.
    pub file: PathBuf,
    /// The name the stored name starts from (default: the file's name).
    #[arg(long)]
    pub name: Option<String>,
}

pub fn run(args: AttachArgs) -> anyhow::Result<()> {
    // Opening checks that this is a vault (and migrates it) before a file
    // is written into it.
    drop(Vault::open(&args.vault)?);
    let stored =
        attachments::store_file(&args.vault, &args.file, args.name.as_deref()).map_err(refusal)?;
    extract_in_process(&args.vault, &stored)?;
    write_json_line(&mut std::io::stdout(), &serde_json::to_value(stored)?)
}

/// R17 (#136): extracts and indexes the stored file's text in this
/// one-shot process (TD "Extraction at store time, isolated"), unless its
/// path already has a final `attachments` row (R44). The vault is open only
/// for the check and the row writes, never while extracting.
fn extract_in_process(vault: &Path, stored: &StoredAttachment) -> anyhow::Result<()> {
    if attachments_extract::is_extracted(Vault::open(vault)?.connection_ref(), &stored.path)? {
        return Ok(());
    }
    let outcome = attachments_extract::extract(&vault.join(&stored.path), &stored.name);
    let mut v = Vault::open(vault)?;
    attachments_extract::record(v.connection_mut(), stored, &outcome, now_unix_ms())?;
    Ok(())
}

/// Core's `Io(InvalidInput)` (an R15 refusal) as `invalid_argument` with its
/// text; any other error as itself.
fn refusal(e: MemexError) -> anyhow::Error {
    match e {
        MemexError::Io(io) if io.kind() == ErrorKind::InvalidInput => {
            InvalidArgument(io.to_string()).into()
        }
        e => e.into(),
    }
}
