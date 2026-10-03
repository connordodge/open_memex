//! `memex prompt` (CONTRACTS C2.13): print a prompt's raw text.

use clap::{Args, Subcommand};

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

pub fn run(args: PromptArgs) -> anyhow::Result<()> {
    match args.command {
        PromptCommand::Review => super::not_implemented("prompt review"),
        PromptCommand::Capture => super::not_implemented("prompt capture"),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn stubs_report_not_implemented() {
        for (command, name) in [
            (PromptCommand::Review, "prompt review"),
            (PromptCommand::Capture, "prompt capture"),
        ] {
            let err = run(PromptArgs { command }).unwrap_err();
            assert_eq!(
                err.to_string(),
                format!("memex {name}: not implemented yet")
            );
        }
    }
}
