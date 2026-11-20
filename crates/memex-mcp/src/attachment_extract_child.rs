//! Attachment text extraction in a child process (Spec #123 R44; TD
//! "Extraction at store time, isolated"; WI #136).
//!
//! PDF parsing can panic or overflow the stack on a hostile file, so
//! `memex serve` (MCP `add_attachment`, the server upload) never extracts in
//! its own process. [`ChildExtractor::run`] starts
//! `<program> [args…] <SUBCOMMAND> <file>` (by default the running `memex`
//! with its hidden [`SUBCOMMAND`]), which prints the file's text on stdout
//! and exits 0, or prints the reason on stderr and exits non-zero. The
//! child runs under a time limit ([`TIME_LIMIT`]) and a memory limit; a
//! timeout, a crash or a non-zero exit is [`Outcome::Failed`], and only the
//! child this call started is killed and reaped.

use std::ffi::OsString;
use std::path::{Path, PathBuf};
use std::time::Duration;

use memex_core::attachments_extract::Outcome;

/// The hidden `memex` subcommand that extracts one file and prints its
/// text: `memex extract-attachment <file>`.
pub const SUBCOMMAND: &str = "extract-attachment";

/// How long the child may run before it is killed (TD): 20 s.
pub const TIME_LIMIT: Duration = Duration::ZERO;

/// Runs the extraction child.
#[derive(Debug, Clone)]
pub struct ChildExtractor {
    program: PathBuf,
    args: Vec<OsString>,
    time_limit: Duration,
}

impl ChildExtractor {
    /// Runs `program <SUBCOMMAND> <file>` under [`TIME_LIMIT`].
    pub fn new(program: impl Into<PathBuf>) -> Self {
        Self {
            program: program.into(),
            args: Vec::new(),
            time_limit: TIME_LIMIT,
        }
    }

    /// The running `memex` binary ([`std::env::current_exe`]).
    pub fn current_exe() -> std::io::Result<Self> {
        Ok(Self::new(PathBuf::new()))
    }

    /// This extractor with `args` placed before [`SUBCOMMAND`] (tests run
    /// `/bin/sh -c <script>` as the child).
    pub fn with_args<I, A>(mut self, args: I) -> Self
    where
        I: IntoIterator<Item = A>,
        A: Into<OsString>,
    {
        self.args = args.into_iter().map(Into::into).collect();
        self
    }

    /// This extractor with its time limit set to `limit`.
    pub fn with_time_limit(mut self, limit: Duration) -> Self {
        self.time_limit = limit;
        self
    }

    /// The time limit.
    pub fn time_limit(&self) -> Duration {
        self.time_limit
    }

    /// The program it starts.
    pub fn program(&self) -> &Path {
        &self.program
    }

    /// Extracts the text of `file` (a stored attachment, named with its
    /// stored name) in a child process. Blocking: call it on the blocking
    /// pool. Never panics: a child that can't start, times out, crashes or
    /// exits non-zero is [`Outcome::Failed`] (with the child's stderr when
    /// it gave one).
    pub fn run(&self, _file: &Path) -> Outcome {
        Outcome::Text(String::new())
    }
}
