//! `memex excerpt` (CONTRACTS C2.4): manage a topic note's excerpts.

use std::path::PathBuf;

use clap::{Args, Subcommand};

/// `memex excerpt <command>`
#[derive(Args, Debug)]
pub struct ExcerptArgs {
    #[command(subcommand)]
    pub command: ExcerptCommand,
}

#[derive(Subcommand, Debug)]
pub enum ExcerptCommand {
    /// Remove one transclusion from a topic note.
    Rm(ExcerptRmArgs),
}

/// `memex excerpt rm --vault V --topic-note-id T --date YYYY-MM-DD
/// --block-ids b7k2m9[,c3d4e5]`
#[derive(Args, Debug)]
pub struct ExcerptRmArgs {
    /// Vault directory.
    #[arg(long)]
    pub vault: PathBuf,
    /// Topic note id (ULID).
    #[arg(long)]
    pub topic_note_id: String,
    /// The daily note's date, YYYY-MM-DD.
    #[arg(long)]
    pub date: String,
    /// The transclusion's endpoint block ids: one id, or `from,to` for a range.
    #[arg(long, value_delimiter = ',', required = true)]
    pub block_ids: Vec<String>,
}

pub fn run(args: ExcerptArgs) -> anyhow::Result<()> {
    match args.command {
        ExcerptCommand::Rm(_) => super::not_implemented("excerpt rm"),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn stub_reports_not_implemented() {
        let err = run(ExcerptArgs {
            command: ExcerptCommand::Rm(ExcerptRmArgs {
                vault: PathBuf::from("v"),
                topic_note_id: "t".into(),
                date: "2026-10-03".into(),
                block_ids: vec!["b7k2m9".into()],
            }),
        })
        .unwrap_err();
        assert_eq!(err.to_string(), "memex excerpt rm: not implemented yet");
    }
}
