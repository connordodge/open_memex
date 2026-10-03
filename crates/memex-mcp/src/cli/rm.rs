//! `memex rm` (CONTRACTS C2.2): delete a note with optimistic concurrency.

use std::path::PathBuf;

use clap::Args;

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

pub fn run(args: RmArgs) -> anyhow::Result<()> {
    let _ = args;
    super::not_implemented("rm")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn stub_reports_not_implemented() {
        let err = run(RmArgs {
            vault: PathBuf::from("v"),
            note_id: "n".into(),
            expected_version: 1,
        })
        .unwrap_err();
        assert_eq!(err.to_string(), "memex rm: not implemented yet");
    }
}
