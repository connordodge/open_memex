//! WI #316 (R0, ruling D13): `memex backup` and `memex restore` flags.
//!
//! `memex backup --vault <path> --dest <dir> [--keep <n>] [--if-changed]`,
//! `--keep` a u16 in 1..=365, default 30; `memex restore --from <file> --to
//! <folder>`. Usage errors are clap's: exit 2, nothing touched. Other
//! failures are one C1 line on stderr and exit 1 (CONTRACTS C1). The help
//! goldens live in `cli_golden.rs`. Success output is R1b's / R2's
//! (`cli_backup.rs`, `cli_restore.rs`); the print seam is pinned here.

use std::io::{self, Write};
use std::path::{Path, PathBuf};
use std::process::{Command, Output};

use clap::{Parser, Subcommand};
use memex_core::backup::{KEEP_DEFAULT, KEEP_MAX};
use memex_mcp::cli::backup::BackupArgs;
use memex_mcp::cli::restore::RestoreArgs;
use memex_mcp::cli::write_json_line;
use serde_json::{json, Value};
use tempfile::TempDir;

/// The two subcommands as `main.rs` registers them.
#[derive(Parser, Debug)]
#[command(name = "memex")]
struct TestCli {
    #[command(subcommand)]
    command: TestCommand,
}

#[derive(Subcommand, Debug)]
enum TestCommand {
    Backup(BackupArgs),
    Restore(RestoreArgs),
}

fn parse_backup(args: &[&str]) -> Result<BackupArgs, clap::Error> {
    let argv = ["memex", "backup"].iter().chain(args.iter());
    match TestCli::try_parse_from(argv)?.command {
        TestCommand::Backup(a) => Ok(a),
        other => panic!("parsed as {other:?}"),
    }
}

fn parse_restore(args: &[&str]) -> Result<RestoreArgs, clap::Error> {
    let argv = ["memex", "restore"].iter().chain(args.iter());
    match TestCli::try_parse_from(argv)?.command {
        TestCommand::Restore(a) => Ok(a),
        other => panic!("parsed as {other:?}"),
    }
}

fn memex(args: &[&str]) -> Output {
    Command::new(env!("CARGO_BIN_EXE_memex"))
        .args(args)
        .output()
        .expect("spawn memex")
}

fn describe(out: &Output) -> String {
    format!(
        "exit={:?}\nstdout={}\nstderr={}",
        out.status.code(),
        String::from_utf8_lossy(&out.stdout),
        String::from_utf8_lossy(&out.stderr)
    )
}

fn listing(dir: &Path) -> Vec<String> {
    let mut names: Vec<String> = std::fs::read_dir(dir)
        .unwrap()
        .map(|e| e.unwrap().file_name().to_string_lossy().into_owned())
        .collect();
    names.sort();
    names
}

/// A temp vault folder and an existing destination, both with a space.
struct Fx {
    _tmp: TempDir,
    vault: PathBuf,
    dest: PathBuf,
}

impl Fx {
    fn new() -> Self {
        let tmp = TempDir::new().unwrap();
        let vault = tmp.path().join("my notes");
        let dest = tmp.path().join("My Drive");
        std::fs::create_dir(&vault).unwrap();
        std::fs::write(vault.join("manifest.json"), "{}").unwrap();
        std::fs::create_dir(&dest).unwrap();
        Fx {
            _tmp: tmp,
            vault,
            dest,
        }
    }

    fn v(&self) -> &str {
        self.vault.to_str().unwrap()
    }

    fn d(&self) -> &str {
        self.dest.to_str().unwrap()
    }
}

// ---------------------------------------------------------------------------
// Parsing (the clap definitions in cli/backup.rs and cli/restore.rs)
// ---------------------------------------------------------------------------

#[test]
fn backup_parses_vault_dest_keep_and_if_changed() {
    let a = parse_backup(&[
        "--vault",
        "/Users/person/my notes",
        "--dest",
        "/Users/person/Library/CloudStorage/My Drive",
        "--keep",
        "7",
        "--if-changed",
    ])
    .unwrap();
    assert_eq!(a.vault, PathBuf::from("/Users/person/my notes"));
    assert_eq!(
        a.dest,
        PathBuf::from("/Users/person/Library/CloudStorage/My Drive")
    );
    assert_eq!(a.keep, 7);
    assert!(a.if_changed);
}

#[test]
fn backup_keep_defaults_to_30_and_if_changed_to_off() {
    let a = parse_backup(&["--vault", "v", "--dest", "d"]).unwrap();
    assert_eq!(a.keep, 30);
    assert_eq!(a.keep, KEEP_DEFAULT);
    assert!(!a.if_changed);
    assert_eq!(a.vault, PathBuf::from("v"));
    assert_eq!(a.dest, PathBuf::from("d"));
}

#[test]
fn backup_keep_accepts_both_bounds_1_and_365() {
    assert_eq!(
        parse_backup(&["--vault", "v", "--dest", "d", "--keep", "1"])
            .unwrap()
            .keep,
        1
    );
    let max = KEEP_MAX.to_string();
    assert_eq!(
        parse_backup(&["--vault", "v", "--dest", "d", "--keep", &max])
            .unwrap()
            .keep,
        365
    );
}

#[test]
fn backup_keep_outside_1_to_365_is_a_clap_value_error() {
    // Control: an in-range value parses.
    assert!(parse_backup(&["--vault", "v", "--dest", "d", "--keep", "2"]).is_ok());
    for bad in ["0", "366", "x", "65536", "", "3.5"] {
        let err = parse_backup(&["--vault", "v", "--dest", "d", "--keep", bad]).expect_err(bad);
        assert_eq!(err.exit_code(), 2, "{bad:?}: {err}");
        assert!(err.to_string().contains("--keep"), "{bad:?}: {err}");
    }
}

#[test]
fn backup_and_restore_require_every_path_flag() {
    assert!(
        parse_backup(&["--vault", "v", "--dest", "d"]).is_ok(),
        "control"
    );
    for (args, missing) in [
        (vec!["--dest", "d"], "--vault"),
        (vec!["--vault", "v"], "--dest"),
    ] {
        let err = parse_backup(&args).expect_err(missing);
        assert!(err.to_string().contains(missing), "{missing}: {err}");
    }
    assert!(
        parse_restore(&["--from", "f", "--to", "t"]).is_ok(),
        "control"
    );
    for (args, missing) in [(vec!["--to", "t"], "--from"), (vec!["--from", "f"], "--to")] {
        let err = parse_restore(&args).expect_err(missing);
        assert!(err.to_string().contains(missing), "{missing}: {err}");
    }
}

#[test]
fn restore_parses_from_and_to() {
    let a = parse_restore(&[
        "--from",
        "/Users/person/My Drive/notes-20261109T090000Z-01JCB7Q4M8V2X5N9R3T6W0YZAE.memex.zip",
        "--to",
        "/Users/person/Documents/notes restored",
    ])
    .unwrap();
    assert_eq!(
        a.from,
        PathBuf::from(
            "/Users/person/My Drive/notes-20261109T090000Z-01JCB7Q4M8V2X5N9R3T6W0YZAE.memex.zip"
        )
    );
    assert_eq!(
        a.to,
        PathBuf::from("/Users/person/Documents/notes restored")
    );
    let err = parse_restore(&["--from", "f", "--to", "t", "--keep", "3"]).expect_err("no --keep");
    assert_eq!(err.exit_code(), 2);
}

// ---------------------------------------------------------------------------
// The real binary: registration in main.rs, exit codes
// ---------------------------------------------------------------------------

#[test]
fn memex_backup_keep_0_366_and_x_exit_2_and_touch_nothing() {
    let fx = Fx::new();
    let vault_before = listing(&fx.vault);
    for bad in ["0", "366", "x"] {
        let out = memex(&["backup", "--vault", fx.v(), "--dest", fx.d(), "--keep", bad]);
        assert_eq!(
            out.status.code(),
            Some(2),
            "--keep {bad}: {}",
            describe(&out)
        );
        let stderr = String::from_utf8_lossy(&out.stderr);
        assert!(
            stderr.contains("--keep"),
            "clap names --keep for {bad:?}: {}",
            describe(&out)
        );
        assert!(out.stdout.is_empty(), "{}", describe(&out));
        assert_eq!(listing(&fx.dest), Vec::<String>::new(), "--keep {bad}");
        assert_eq!(listing(&fx.vault), vault_before, "--keep {bad}");
    }
}

#[test]
fn memex_backup_and_restore_without_their_flags_exit_2_naming_the_flag() {
    let fx = Fx::new();
    for (args, flag) in [
        (vec!["backup", "--vault", fx.v()], "--dest"),
        (vec!["backup", "--dest", fx.d()], "--vault"),
        (vec!["restore", "--to", fx.d()], "--from"),
        (vec!["restore", "--from", fx.v()], "--to"),
    ] {
        let out = memex(&args);
        assert_eq!(out.status.code(), Some(2), "{args:?}: {}", describe(&out));
        assert!(
            String::from_utf8_lossy(&out.stderr).contains(flag),
            "{args:?} names {flag}: {}",
            describe(&out)
        );
    }
}

/// A failure that isn't a usage error is one C1 line on stderr, exit 1,
/// nothing on stdout. (Which code a missing vault or file gets is R1b's and
/// R2's: `internal`.)
fn assert_one_c1_line(out: &Output) {
    assert_eq!(out.status.code(), Some(1), "{}", describe(out));
    assert!(
        out.stdout.is_empty(),
        "nothing on stdout: {}",
        describe(out)
    );
    let stderr = String::from_utf8(out.stderr.clone()).unwrap();
    assert_eq!(
        stderr.matches('\n').count(),
        1,
        "one line: {}",
        describe(out)
    );
    let v: Value = serde_json::from_str(stderr.trim_end()).expect("stderr is JSON");
    let err = v["error"].as_object().expect("C1 {\"error\":{…}}");
    assert!(err["code"].is_string(), "{v}");
    assert!(err["message"].is_string(), "{v}");
}

#[test]
fn memex_backup_failure_is_one_c1_line_on_stderr_and_exit_1() {
    let fx = Fx::new();
    let missing = fx.vault.with_file_name("no such vault");
    let out = memex(&[
        "backup",
        "--vault",
        missing.to_str().unwrap(),
        "--dest",
        fx.d(),
    ]);
    assert_one_c1_line(&out);
    assert_eq!(listing(&fx.dest), Vec::<String>::new());
}

#[test]
fn memex_restore_failure_is_one_c1_line_on_stderr_and_exit_1() {
    let fx = Fx::new();
    let from = fx.dest.join("missing.memex.zip");
    let to = fx.dest.join("restored vault");
    let out = memex(&[
        "restore",
        "--from",
        from.to_str().unwrap(),
        "--to",
        to.to_str().unwrap(),
    ]);
    assert_one_c1_line(&out);
    assert!(!to.exists(), "--to is not created");
}

// ---------------------------------------------------------------------------
// The print seam (req 17, 17a, 34): one line, written last, BrokenPipe ignored
// ---------------------------------------------------------------------------

#[test]
fn write_json_line_prints_one_compact_json_line() {
    let value = json!({
        "result": "created",
        "vault_id": "01JCB7Q4M8V2X5N9R3T6W0YZAE",
        "file": "/Users/person/My Drive/notes-20261109T090000Z-01JCB7Q4M8V2X5N9R3T6W0YZAE.memex.zip",
        "bytes": 48213,
        "fingerprint": "ab",
        "removed": []
    });
    let mut out = Vec::new();
    write_json_line(&mut out, &value).unwrap();
    let text = String::from_utf8(out).unwrap();
    assert_eq!(text, format!("{value}\n"));
    assert_eq!(text.matches('\n').count(), 1, "{text:?}");
    let back: Value = serde_json::from_str(text.trim_end()).unwrap();
    assert_eq!(back, value);
}

/// A stdout whose reader went away (the app quit): every write fails with
/// BrokenPipe. The command still succeeds; its effects already happened.
struct ClosedPipe {
    attempted: Vec<u8>,
}

impl Write for ClosedPipe {
    fn write(&mut self, buf: &[u8]) -> io::Result<usize> {
        self.attempted.extend_from_slice(buf);
        Err(io::Error::from(io::ErrorKind::BrokenPipe))
    }
    fn flush(&mut self) -> io::Result<()> {
        Err(io::Error::from(io::ErrorKind::BrokenPipe))
    }
}

#[test]
fn write_json_line_ignores_a_closed_stdout() {
    let mut out = ClosedPipe {
        attempted: Vec::new(),
    };
    let value = json!({"vault_id": "01JCB7Q4M8V2X5N9R3T6W0YZAE", "path": "/p", "created_at": 1});
    let result = write_json_line(&mut out, &value);
    assert!(
        !out.attempted.is_empty(),
        "the line was written to stdout before the pipe error"
    );
    assert!(result.is_ok(), "BrokenPipe is not a failure: {result:?}");
}

struct FullDisk;

impl Write for FullDisk {
    fn write(&mut self, _buf: &[u8]) -> io::Result<usize> {
        Err(io::Error::other("no space left on device"))
    }
    fn flush(&mut self) -> io::Result<()> {
        Ok(())
    }
}

#[test]
fn write_json_line_reports_other_write_errors() {
    let mut ok = Vec::new();
    write_json_line(&mut ok, &json!({"a": 1})).unwrap();
    assert_eq!(ok, b"{\"a\":1}\n", "control");
    let err = write_json_line(&mut FullDisk, &json!({"a": 1})).expect_err("not BrokenPipe");
    assert!(format!("{err:#}").contains("no space left"), "{err:#}");
}

/// A stdout that accepts the line and records what happened to it.
#[derive(Default)]
struct Recording {
    written: Vec<u8>,
    flushed_len: Vec<usize>,
    flush_error: Option<io::ErrorKind>,
}

impl Write for Recording {
    fn write(&mut self, buf: &[u8]) -> io::Result<usize> {
        self.written.extend_from_slice(buf);
        Ok(buf.len())
    }
    fn flush(&mut self) -> io::Result<()> {
        self.flushed_len.push(self.written.len());
        match self.flush_error {
            Some(kind) => Err(io::Error::from(kind)),
            None => Ok(()),
        }
    }
}

/// Verify-mode pin (the doc says "after every effect"): the line is flushed
/// once, after it was written, so a piped stdout sees it before the process
/// exits.
#[test]
fn write_json_line_flushes_once_after_the_line_is_written() {
    let mut out = Recording::default();
    write_json_line(&mut out, &json!({"a": 1})).unwrap();
    assert_eq!(out.written, b"{\"a\":1}\n");
    assert_eq!(out.flushed_len, vec![out.written.len()]);
}

#[test]
fn write_json_line_treats_a_closed_pipe_on_flush_as_success_and_other_flush_errors_as_failure() {
    let mut closed = Recording {
        flush_error: Some(io::ErrorKind::BrokenPipe),
        ..Recording::default()
    };
    write_json_line(&mut closed, &json!({"a": 1})).expect("BrokenPipe on flush is not a failure");
    assert_eq!(closed.written, b"{\"a\":1}\n");

    let mut broken = Recording {
        flush_error: Some(io::ErrorKind::PermissionDenied),
        ..Recording::default()
    };
    let err =
        write_json_line(&mut broken, &json!({"a": 1})).expect_err("a flush error is reported");
    assert!(
        format!("{err:#}").to_lowercase().contains("permission"),
        "{err:#}"
    );
}
