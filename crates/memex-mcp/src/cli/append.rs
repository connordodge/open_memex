//! `memex append` (CONTRACTS C2.12): append text to a daily note.

use std::path::PathBuf;

use clap::Args;

/// `memex append --vault V [--date YYYY-MM-DD] [TEXT]` (stdin when TEXT is
/// absent).
#[derive(Args, Debug)]
pub struct AppendArgs {
    /// Vault directory.
    #[arg(long)]
    pub vault: PathBuf,
    /// Daily note date, YYYY-MM-DD (default: today, local time).
    #[arg(long)]
    pub date: Option<String>,
    /// Text to append (read from stdin when omitted).
    pub text: Option<String>,
}

pub fn run(args: AppendArgs) -> anyhow::Result<()> {
    let _ = args;
    super::not_implemented("append")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn stub_reports_not_implemented() {
        let err = run(AppendArgs {
            vault: PathBuf::from("v"),
            date: None,
            text: None,
        })
        .unwrap_err();
        assert_eq!(err.to_string(), "memex append: not implemented yet");
    }
}
