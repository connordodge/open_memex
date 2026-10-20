//! `memex prompt` (CONTRACTS C2.13): print a prompt's raw text.

use std::io::Write;

use clap::{Args, Subcommand};

use crate::ops::prompt::{self, PromptKind};
use crate::prompts::{CAPTURE, REVIEW_DAILY_NOTES};

/// `memex prompt review` / `memex prompt capture`
#[derive(Args, Debug)]
pub struct PromptArgs {
    #[command(subcommand)]
    pub command: PromptCommand,
}

#[derive(Subcommand, Debug)]
pub enum PromptCommand {
    /// Print the review prompt.
    Review,
    /// Print the capture prompt.
    Capture,
}

impl PromptCommand {
    /// The `prompts.rs` constant this command prints (D18).
    pub fn text(&self) -> &'static str {
        match self {
            PromptCommand::Review => REVIEW_DAILY_NOTES,
            PromptCommand::Capture => CAPTURE,
        }
    }
}

/// Writes the prompt text byte-for-byte: no JSON and no added newline (the
/// constants already end with one).
pub fn run(args: PromptArgs) -> anyhow::Result<()> {
    let kind = match args.command {
        PromptCommand::Review => PromptKind::Review,
        PromptCommand::Capture => PromptKind::Capture,
    };
    let out = prompt::get(kind)?;
    let mut stdout = std::io::stdout().lock();
    stdout.write_all(out.text.as_bytes())?;
    stdout.flush()?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn each_command_maps_to_its_own_constant() {
        assert_eq!(PromptCommand::Review.text(), REVIEW_DAILY_NOTES);
        assert_eq!(PromptCommand::Capture.text(), CAPTURE);
        for text in [REVIEW_DAILY_NOTES, CAPTURE] {
            assert!(text.ends_with('\n') && !text.ends_with("\n\n"));
        }
    }
}
