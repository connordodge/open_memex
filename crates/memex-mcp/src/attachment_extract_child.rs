//! Attachment text extraction in a child process (Spec #123 R44; TD
//! "Extraction at store time, isolated"; WI #136).
//!
//! PDF parsing can panic or overflow the stack on a hostile file, so
//! `memex serve` (MCP `add_attachment`, the server upload) never extracts in
//! its own process. [`ChildExtractor::run`] starts
//! `<program> [args…] <SUBCOMMAND> <file>` (by default the running `memex`
//! with its hidden [`SUBCOMMAND`]), which prints the file's text on stdout
//! and exits 0, or prints the reason on stderr and exits non-zero. The
//! child runs under a time limit ([`TIME_LIMIT`]) and a memory limit the
//! subcommand sets on itself: on Linux the kernel's `RLIMIT_DATA`
//! ([`memex_core::attachments_extract::cap_data_memory`]), and on macOS
//! and Linux a peak-resident watchdog
//! ([`memex_core::attachments_extract::limit_memory`]). A timeout, a crash
//! or a non-zero exit is [`Outcome::Failed`], and only the child this call
//! started is killed and reaped. At most [`MAX_CHILDREN`] children of one
//! extractor run at once.
//!
//! [`extract_and_record`] is what the serve routes call after a store: it
//! skips a file already extracted, runs the child without holding the
//! vault lock, then takes the lock once to write the rows. `memex attach`
//! runs the same child through [`extract_and_record_blocking`].

use std::ffi::OsString;
use std::io::{Read, Write};
use std::path::{Path, PathBuf};
use std::process::{Command, ExitCode, ExitStatus, Stdio};
use std::sync::{mpsc, Arc, OnceLock};
use std::time::{Duration, Instant};

use memex_core::attachments::StoredAttachment;
use memex_core::attachments_extract::{
    self, decode_text, extract, extracts_text, is_extracted, record, Outcome, MAX_TEXT_BYTES,
    MEMORY_LIMIT_BYTES,
};
use memex_core::{now_unix_ms, MemexError, Result, Vault};
use tokio::sync::Semaphore;

use crate::state::AppState;

/// The hidden `memex` subcommand that extracts one file and prints its
/// text: `memex extract-attachment <file>`.
pub const SUBCOMMAND: &str = "extract-attachment";

/// How long the child may run before it is killed (TD): 20 s.
pub const TIME_LIMIT: Duration = Duration::from_secs(20);

/// The most extraction children [`extract_and_record`] runs at once for
/// one extractor (and its clones): 2. Further stores wait for a turn, so N
/// concurrent uploads of a hostile PDF never start N children.
pub const MAX_CHILDREN: usize = 2;

/// The most bytes of the child's stderr kept for `extract_error`.
const MAX_ERROR_BYTES: usize = 4096;

/// How long the output readers may take to finish once the child has
/// ended (a grandchild holding a pipe open is not waited for longer).
const DRAIN_LIMIT: Duration = Duration::from_secs(2);

/// The longest pause between two checks on a running child.
const MAX_POLL: Duration = Duration::from_millis(25);

/// Runs the extraction child. Clones share one set of [`MAX_CHILDREN`]
/// turns.
#[derive(Debug, Clone)]
pub struct ChildExtractor {
    program: PathBuf,
    args: Vec<OsString>,
    time_limit: Duration,
    turns: Arc<Semaphore>,
}

impl ChildExtractor {
    /// Runs `program <SUBCOMMAND> <file>` under [`TIME_LIMIT`].
    pub fn new(program: impl Into<PathBuf>) -> Self {
        Self {
            program: program.into(),
            args: Vec::new(),
            time_limit: TIME_LIMIT,
            turns: Arc::new(Semaphore::new(MAX_CHILDREN)),
        }
    }

    /// The running `memex` binary ([`std::env::current_exe`]).
    pub fn current_exe() -> std::io::Result<Self> {
        Ok(Self::new(std::env::current_exe()?))
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
    pub fn run(&self, file: &Path) -> Outcome {
        let mut child = match Command::new(&self.program)
            .args(&self.args)
            .arg(SUBCOMMAND)
            .arg(file)
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
        {
            Ok(child) => child,
            Err(e) => {
                return Outcome::Failed(format!(
                    "the extraction child {} could not start: {e}",
                    self.program.display()
                ))
            }
        };
        // Both pipes are drained while the child runs, so a large output
        // never blocks it.
        let stdout = reader(child.stdout.take(), MAX_TEXT_BYTES);
        let stderr = reader(child.stderr.take(), MAX_ERROR_BYTES);

        let deadline = Instant::now() + self.time_limit;
        let mut pause = Duration::from_millis(1);
        let ended: std::result::Result<ExitStatus, String> = loop {
            match child.try_wait() {
                Ok(Some(status)) => break Ok(status),
                Ok(None) => {}
                Err(e) => {
                    stop(&mut child);
                    break Err(format!("the extraction child could not be watched: {e}"));
                }
            }
            let now = Instant::now();
            if now >= deadline {
                stop(&mut child);
                break Err(format!(
                    "extraction took longer than {} s and was stopped",
                    self.time_limit.as_secs_f64()
                ));
            }
            std::thread::sleep(std::cmp::min(pause, deadline - now));
            pause = std::cmp::min(pause * 2, MAX_POLL);
        };
        let stdout = collect(&stdout);
        let stderr = collect(&stderr).unwrap_or_default();
        let stderr = String::from_utf8_lossy(&stderr).trim().to_string();
        match (ended, stdout) {
            (Err(why), _) => Outcome::Failed(why),
            (Ok(status), Some(stdout)) if status.success() => Outcome::Text(decode_text(&stdout)),
            // Its text may be cut short: not a final `empty` or `done`.
            (Ok(status), None) if status.success() => Outcome::Failed(format!(
                "the extraction child's output did not end within {} s of it exiting",
                DRAIN_LIMIT.as_secs_f64()
            )),
            (Ok(status), _) => Outcome::Failed(failure(status, &stderr)),
        }
    }
}

/// The extractor of every state that sets none: the running `memex`
/// ([`ChildExtractor::current_exe`]), one per process so all its vaults
/// share its [`MAX_CHILDREN`] turns. The error says why there is none.
fn default_extractor() -> std::result::Result<&'static ChildExtractor, &'static str> {
    static DEFAULT: OnceLock<std::result::Result<ChildExtractor, String>> = OnceLock::new();
    DEFAULT
        .get_or_init(|| {
            ChildExtractor::current_exe()
                .map_err(|e| format!("the extraction child was not found: {e}"))
        })
        .as_ref()
        .map_err(String::as_str)
}

/// Kills the child this runner started (by its own handle, so only that
/// process) and reaps it.
fn stop(child: &mut std::process::Child) {
    let _ = child.kill();
    let _ = child.wait();
}

/// The `extract_error` of a child that ended with `status`.
fn failure(status: ExitStatus, stderr: &str) -> String {
    match (status.code(), stderr.is_empty()) {
        (Some(_), false) => stderr.to_string(),
        (Some(code), true) => format!("the extraction child exited with status {code}"),
        (None, false) => format!("the extraction child crashed ({status}): {stderr}"),
        (None, true) => format!("the extraction child crashed ({status})"),
    }
}

/// Reads `pipe` to its end on a thread, keeping its first `cap` bytes.
fn reader<R: Read + Send + 'static>(pipe: Option<R>, cap: usize) -> mpsc::Receiver<Vec<u8>> {
    let (tx, rx) = mpsc::channel();
    std::thread::spawn(move || {
        let mut kept = Vec::new();
        if let Some(mut pipe) = pipe {
            let mut buf = [0u8; 64 * 1024];
            loop {
                match pipe.read(&mut buf) {
                    Ok(0) => break,
                    Ok(n) => {
                        let room = cap.saturating_sub(kept.len());
                        kept.extend_from_slice(&buf[..std::cmp::min(n, room)]);
                    }
                    Err(e) if e.kind() == std::io::ErrorKind::Interrupted => {}
                    Err(_) => break,
                }
            }
        }
        let _ = tx.send(kept);
    });
    rx
}

/// What a [`reader`] kept, once the pipe has closed (`None` when it is
/// still open after [`DRAIN_LIMIT`]).
fn collect(rx: &mpsc::Receiver<Vec<u8>>) -> Option<Vec<u8>> {
    rx.recv_timeout(DRAIN_LIMIT).ok()
}

/// Extracts and indexes `stored` for a vault `memex serve` holds (R17):
/// nothing when its path already has a final `attachments` row (R44);
/// otherwise its text through the child (no child for a type with no
/// text), then one short lock of the vault to [`record`] the outcome. The
/// vault lock is never held while the child runs (TD "No vault lease during
/// heavy work"). A child runs only on one of the extractor's
/// [`MAX_CHILDREN`] turns, and the path is checked again once the turn
/// comes, so a store of the same file that waited runs no second child.
///
/// The work runs on its own task: a caller that stops waiting (a dropped
/// request) still leaves the row written. A failed extraction is recorded,
/// not returned: only a database error is.
pub async fn extract_and_record(state: &AppState, stored: &StoredAttachment) -> Result<()> {
    let state = state.clone();
    let stored = stored.clone();
    tokio::spawn(async move { extract_and_record_here(&state, &stored).await })
        .await
        .map_err(|e| task_error("the attachment extraction task failed", e))?
}

async fn extract_and_record_here(state: &AppState, stored: &StoredAttachment) -> Result<()> {
    if extracted(state, stored).await? {
        return Ok(());
    }
    let outcome = if extracts_text(&stored.name) {
        let extractor = match &state.extractor {
            Some(extractor) => Ok(extractor.clone()),
            None => default_extractor().cloned(),
        };
        match extractor {
            Ok(extractor) => {
                let _turn =
                    extractor.turns.clone().acquire_owned().await.map_err(|e| {
                        task_error("the attachment extraction turns were closed", e)
                    })?;
                if extracted(state, stored).await? {
                    return Ok(());
                }
                let file = state.vault_path.join(&stored.path);
                tokio::task::spawn_blocking(move || extractor.run(&file))
                    .await
                    .unwrap_or_else(|e| Outcome::Failed(format!("the extraction task failed: {e}")))
            }
            Err(why) => Outcome::Failed(why.to_string()),
        }
    } else {
        Outcome::Text(String::new())
    };
    let mut vault = state.vault.lock().await;
    record(vault.connection_mut(), stored, &outcome, now_unix_ms())?;
    Ok(())
}

/// Whether `stored`'s path already has a final `attachments` row (a short
/// lock of the vault).
async fn extracted(state: &AppState, stored: &StoredAttachment) -> Result<bool> {
    let vault = state.vault.lock().await;
    is_extracted(vault.connection_ref(), &stored.path)
}

/// A task fault as a core error (the routes answer it as `internal`).
fn task_error(what: &str, e: impl std::fmt::Display) -> MemexError {
    MemexError::Io(std::io::Error::other(format!("{what}: {e}")))
}

/// [`extract_and_record`] for the one-shot `memex attach` (R17): the same
/// child, run from this process ([`ChildExtractor::current_exe`]), so a
/// hostile PDF there is stopped by the same time and memory limits and
/// still leaves a `failed` row. The vault is open only for the check and
/// for the row writes, never while the child runs. Blocking.
pub fn extract_and_record_blocking(vault: &Path, stored: &StoredAttachment) -> Result<()> {
    if is_extracted(Vault::open(vault)?.connection_ref(), &stored.path)? {
        return Ok(());
    }
    let outcome = if extracts_text(&stored.name) {
        match default_extractor() {
            Ok(extractor) => extractor.run(&vault.join(&stored.path)),
            Err(why) => Outcome::Failed(why.to_string()),
        }
    } else {
        Outcome::Text(String::new())
    };
    let mut v = Vault::open(vault)?;
    record(v.connection_mut(), stored, &outcome, now_unix_ms())?;
    Ok(())
}

/// `memex extract-attachment <file>`: the child's side. Limits its own
/// memory (the kernel's data limit on Linux, and the watchdog), extracts
/// `file` by its file name's type, and prints the text on stdout (exit 0)
/// or the reason on stderr (exit 1).
pub fn run_subcommand(file: &Path) -> ExitCode {
    attachments_extract::cap_data_memory(MEMORY_LIMIT_BYTES);
    attachments_extract::limit_memory(MEMORY_LIMIT_BYTES);
    let name = file
        .file_name()
        .map(|n| n.to_string_lossy().into_owned())
        .unwrap_or_default();
    match extract(file, &name) {
        Outcome::Text(text) => {
            let mut out = std::io::stdout().lock();
            match out.write_all(text.as_bytes()).and_then(|()| out.flush()) {
                Ok(()) => ExitCode::SUCCESS,
                Err(e) => {
                    eprintln!("the text could not be written: {e}");
                    ExitCode::FAILURE
                }
            }
        }
        Outcome::Failed(why) => {
            eprintln!("{why}");
            ExitCode::FAILURE
        }
    }
}
