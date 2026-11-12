//! The `memex` subcommands added for daily notes (architect ruling D6).
//!
//! Each area owns one file and defines its own clap types plus a
//! `pub fn run(args) -> anyhow::Result<()>`; `main.rs` only registers the
//! variant and delegates. Failures are reported through [`error_json`]
//! (CONTRACTS C1): one line of JSON on stderr and exit code 1.

use std::fmt;

use memex_core::MemexError;
use serde_json::{json, Value};

pub mod append;
pub mod backup;
pub mod echoes;
pub mod embeddings;
pub mod excerpt;
pub mod feedback;
pub mod filing;
pub mod folder;
pub mod footer;
pub mod guide;
pub mod prompt;
pub mod restore;
pub mod rm;
pub mod serve;
pub mod settings;
pub mod tag;
pub mod tools;
pub mod vault;
pub mod words;

/// A note role (`role` frontmatter key): `--role` on `memex add` and the
/// `role` parameter of MCP `create_note`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, clap::ValueEnum)]
pub enum Role {
    Daily,
    Topic,
}

impl Role {
    /// The frontmatter value.
    pub fn as_str(self) -> &'static str {
        match self {
            Role::Daily => "daily",
            Role::Topic => "topic",
        }
    }

    /// Exact, case-sensitive match on the frontmatter value.
    pub fn parse(s: &str) -> Option<Self> {
        <Self as clap::ValueEnum>::from_str(s, false).ok()
    }
}

/// A CLI argument the core never saw (empty stdin, a malformed `--kind`).
/// Reported with code `invalid_argument`.
#[derive(Debug)]
pub struct InvalidArgument(pub String);

impl fmt::Display for InvalidArgument {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.0)
    }
}

impl std::error::Error for InvalidArgument {}

/// A failure that names its own C1 code, such as the `memex serve --remote`
/// bridge's `access_token_missing`, `server_unreachable`, `unauthorized` and
/// `vault_not_found`.
#[derive(Debug)]
pub struct CodedError {
    pub code: String,
    pub message: String,
}

impl CodedError {
    pub fn new(code: impl Into<String>, message: impl Into<String>) -> Self {
        Self {
            code: code.into(),
            message: message.into(),
        }
    }
}

impl fmt::Display for CodedError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.message)
    }
}

impl std::error::Error for CodedError {}

/// The CONTRACTS C1 object for a failed subcommand. A [`MemexError`] anywhere
/// it can be downcast (including under `.context(…)`) maps through
/// `to_error_json()`; a [`CodedError`] keeps its code and message; an
/// [`InvalidArgument`] is `invalid_argument`; anything else is `internal`,
/// with the full context chain as the message.
pub fn error_json(err: &anyhow::Error) -> Value {
    if let Some(e) = err.downcast_ref::<MemexError>() {
        return e.to_error_json();
    }
    if let Some(e) = err.downcast_ref::<CodedError>() {
        return json!({ "error": { "code": e.code, "message": e.message } });
    }
    let code = if err.downcast_ref::<InvalidArgument>().is_some() {
        "invalid_argument"
    } else {
        "internal"
    };
    json!({ "error": { "code": code, "message": format!("{err:#}") } })
}

/// Prints `value` as one line of compact JSON on `out` with one `writeln!`,
/// after every effect of the command is done (Spec #315 req 17a). A closed
/// stdout (`BrokenPipe`) is not an error: the effects already happened.
pub fn write_json_line(out: &mut dyn std::io::Write, value: &Value) -> anyhow::Result<()> {
    match writeln!(out, "{value}").and_then(|()| out.flush()) {
        Err(e) if e.kind() != std::io::ErrorKind::BrokenPipe => Err(e.into()),
        _ => Ok(()),
    }
}

/// The result of a subcommand whose behaviour a later Work Item supplies.
pub fn not_implemented(command: &str) -> anyhow::Result<()> {
    anyhow::bail!("memex {command}: not implemented yet")
}

#[cfg(test)]
mod tests {
    use anyhow::Context;

    use super::*;

    #[test]
    fn role_parses_exact_names_only() {
        assert_eq!(Role::parse("daily"), Some(Role::Daily));
        assert_eq!(Role::parse("topic"), Some(Role::Topic));
        for bad in ["", "Topic", "DAILY", "bogus", " topic"] {
            assert_eq!(Role::parse(bad), None, "{bad:?}");
        }
        assert_eq!(Role::Daily.as_str(), "daily");
        assert_eq!(Role::Topic.as_str(), "topic");
    }

    #[test]
    fn memex_error_maps_through_to_error_json_even_under_context() {
        let e = MemexError::VersionConflict {
            expected: 3,
            current: 4,
        };
        let want = e.to_error_json();
        let err = Err::<(), _>(e).context("save note").unwrap_err();
        assert_eq!(error_json(&err), want);
    }

    #[test]
    fn invalid_argument_and_other_errors_get_their_codes() {
        let err = anyhow::Error::new(InvalidArgument("stdin was empty".into()));
        assert_eq!(
            error_json(&err),
            json!({ "error": { "code": "invalid_argument", "message": "stdin was empty" } })
        );

        let err = anyhow::anyhow!("disk on fire").context("open vault");
        assert_eq!(
            error_json(&err),
            json!({ "error": { "code": "internal", "message": "open vault: disk on fire" } })
        );
    }

    #[test]
    fn not_implemented_is_an_internal_error_naming_the_command() {
        let err = not_implemented("folder ls").unwrap_err();
        assert_eq!(err.to_string(), "memex folder ls: not implemented yet");
        assert_eq!(error_json(&err)["error"]["code"], "internal");
    }
}
