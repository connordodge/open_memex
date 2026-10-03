//! `memex footer` (CONTRACTS C2.3): manage a daily note's topic footer.

use std::path::PathBuf;

use clap::{Args, Subcommand};

/// `memex footer <command>`
#[derive(Args, Debug)]
pub struct FooterArgs {
    #[command(subcommand)]
    pub command: FooterCommand,
}

#[derive(Subcommand, Debug)]
pub enum FooterCommand {
    /// Add a topic to a daily note's footer.
    Add(FooterAddArgs),
}

/// `memex footer add --vault V --daily-note-id D --topic-note-id T`
#[derive(Args, Debug)]
pub struct FooterAddArgs {
    /// Vault directory.
    #[arg(long)]
    pub vault: PathBuf,
    /// Daily note id (ULID).
    #[arg(long)]
    pub daily_note_id: String,
    /// Topic note id (ULID).
    #[arg(long)]
    pub topic_note_id: String,
}

pub fn run(args: FooterArgs) -> anyhow::Result<()> {
    match args.command {
        FooterCommand::Add(_) => super::not_implemented("footer add"),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn stub_reports_not_implemented() {
        let err = run(FooterArgs {
            command: FooterCommand::Add(FooterAddArgs {
                vault: PathBuf::from("v"),
                daily_note_id: "d".into(),
                topic_note_id: "t".into(),
            }),
        })
        .unwrap_err();
        assert_eq!(err.to_string(), "memex footer add: not implemented yet");
    }
}
