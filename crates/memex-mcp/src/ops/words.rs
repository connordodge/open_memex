//! Learned-words ops: `memex words ls|add|rm` (Spec #392 requirement 16),
//! which the hosted `/words` routes share. The rules are
//! `memex_core::words`'.

use memex_core::embedder::Embedder;
use memex_core::words::{self, LearnedWord, WordChange};
use memex_core::{Clock, Vault};
use serde::Serialize;

/// The input of [`ls`].
#[derive(Debug, Clone, Copy, Default)]
pub struct LsInput;

/// The `memex words ls` output line.
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct LsOutput {
    pub vault_id: String,
    /// Sorted by `word_key`.
    pub words: Vec<LearnedWord>,
}

/// The input of [`add`].
#[derive(Debug, Clone, Default)]
pub struct AddInput {
    pub word: String,
}

/// The input of [`rm`].
#[derive(Debug, Clone, Default)]
pub struct RmInput {
    pub word: String,
}

/// The `memex words add|rm` output line.
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct WriteOutput {
    pub vault_id: String,
    pub word: String,
    pub changed: bool,
}

/// Lists the learned words.
pub fn ls(
    vault: &mut Vault,
    input: LsInput,
    clock: &dyn Clock,
    embedder: Option<&dyn Embedder>,
) -> anyhow::Result<LsOutput> {
    let _ = (input, clock, embedder);
    Ok(LsOutput {
        vault_id: vault.vault_id().to_string(),
        words: words::list(vault)?,
    })
}

/// Learns a word.
pub fn add(
    vault: &mut Vault,
    input: AddInput,
    clock: &dyn Clock,
    embedder: Option<&dyn Embedder>,
) -> anyhow::Result<WriteOutput> {
    let _ = (clock, embedder);
    let change = words::learn(vault, &input.word)?;
    Ok(write_output(vault, change))
}

/// Forgets a learned word.
pub fn rm(
    vault: &mut Vault,
    input: RmInput,
    clock: &dyn Clock,
    embedder: Option<&dyn Embedder>,
) -> anyhow::Result<WriteOutput> {
    let _ = (clock, embedder);
    let change = words::unlearn(vault, &input.word)?;
    Ok(write_output(vault, change))
}

fn write_output(vault: &Vault, change: WordChange) -> WriteOutput {
    WriteOutput {
        vault_id: vault.vault_id().to_string(),
        word: change.word,
        changed: change.changed,
    }
}
