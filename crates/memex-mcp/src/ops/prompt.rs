//! Prompt ops: `memex prompt review|capture` (C2.13).
//!
//! The one op that needs no vault: `memex prompt` takes no `--vault`.

use serde::Serialize;

/// Which prompt to read.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PromptKind {
    /// The review prompt (`prompts::REVIEW_DAILY_NOTES`).
    Review,
    /// The capture prompt (`prompts::CAPTURE`).
    Capture,
}

/// A prompt's raw text, byte-for-byte as `memex prompt` prints it.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct PromptOutput {
    pub text: String,
}

/// Returns the `prompts.rs` constant for `kind` (D18).
pub fn get(kind: PromptKind) -> anyhow::Result<PromptOutput> {
    let _ = kind;
    anyhow::bail!("ops::prompt::get is not implemented yet (#73)")
}
