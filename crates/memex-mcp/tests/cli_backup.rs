//! WI #318 (R1b): `memex backup` end to end, driving the built binary
//! (Spec #315 req 17, 17a; architecture D13).
//!
//! Success prints one req 17 JSON line on stdout and exits 0: `file`,
//! `removed` and `last_file` are `destination_key(dest)` joined with the
//! file name (absolute, symlinks resolved). A failure prints one C1 line on
//! stderr and exits 1. Every effect (the renamed file, retention,
//! backup-state.json) is done before the line is printed, so a closed
//! stdout skips none of them.
//!
//! Vaults are made with `memex_core::Vault::create` in temp folders whose
//! names contain a space; paths are compared canonical.

use std::collections::BTreeSet;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::{Command, Output, Stdio};

use memex_core::backup::state;
use memex_core::notes::{self, CreateNote};
use memex_core::Vault;
use serde_json::{json, Value};
use tempfile::TempDir;

/// The vault folder and its label (D10: space -> `-`).
const VAULT_FOLDER: &str = "my notes";
const LABEL: &str = "my-notes";

/// A canonical temp root holding the vault `my notes` (one note, one
/// object) and the existing destination `My Drive`.
struct Fx {
    _tmp: TempDir,
    root: PathBuf,
    vault: PathBuf,
    dest: PathBuf,
    vault_id: String,
}

impl Fx {
    fn new() -> Self {
        let tmp = tempfile::Builder::new()
            .prefix("memex cli backup ")
            .tempdir()
            .unwrap();
        let root = fs::canonicalize(tmp.path()).unwrap();
        let vault = root.join(VAULT_FOLDER);
        let dest = root.join("My Drive");
        fs::create_dir(&dest).unwrap();
        let vault_id = {
            let mut v = Vault::create(&vault).unwrap();
            notes::create_note(
                &mut v,
                CreateNote {
                    title: Some("A note".into()),
                    content_md: "# A note\n\nbacked up by the CLI".into(),
                    ..Default::default()
                },
            )
            .unwrap();
            v.vault_id().to_string()
        };
        fs::create_dir_all(vault.join("objects/ab")).unwrap();
        fs::write(vault.join("objects/ab/cd.bin"), b"object bytes").unwrap();
        Fx {
            _tmp: tmp,
            root,
            vault,
            dest,
            vault_id,
        }
    }

    fn v(&self) -> &str {
        self.vault.to_str().unwrap()
    }

    fn d(&self) -> &str {
        self.dest.to_str().unwrap()
    }

    /// A backup file of this vault named for `stamp`, seeded in `My Drive`.
    fn seed_backup(&self, stamp: &str) -> PathBuf {
        let p = self
            .dest
            .join(format!("{LABEL}-{stamp}-{}.memex.zip", self.vault_id));
        fs::write(&p, format!("seeded {stamp}")).unwrap();
        p
    }

    /// This vault's `.memex.zip` files in `My Drive`.
    fn backups(&self) -> BTreeSet<String> {
        fs::read_dir(&self.dest)
            .unwrap()
            .map(|e| e.unwrap().file_name().to_string_lossy().into_owned())
            .filter(|n| {
                !n.starts_with('.') && n.ends_with(&format!("-{}.memex.zip", self.vault_id))
            })
            .collect()
    }
}

fn memex(args: &[&str]) -> Output {
    memex_in(None, args)
}

fn memex_in(cwd: Option<&Path>, args: &[&str]) -> Output {
    let mut cmd = Command::new(env!("CARGO_BIN_EXE_memex"));
    cmd.args(args);
    if let Some(dir) = cwd {
        cmd.current_dir(dir);
    }
    cmd.output().expect("spawn memex")
}

fn describe(out: &Output) -> String {
    format!(
        "exit={:?}\nstdout={}\nstderr={}",
        out.status.code(),
        String::from_utf8_lossy(&out.stdout),
        String::from_utf8_lossy(&out.stderr)
    )
}

/// The one JSON line on stdout of a run that exited 0.
fn success_line(out: &Output) -> Value {
    assert_eq!(out.status.code(), Some(0), "{}", describe(out));
    assert!(
        out.stderr.is_empty(),
        "nothing on stderr: {}",
        describe(out)
    );
    let stdout = String::from_utf8(out.stdout.clone()).unwrap();
    assert_eq!(
        stdout.matches('\n').count(),
        1,
        "one line: {}",
        describe(out)
    );
    assert!(stdout.ends_with('\n'));
    serde_json::from_str(stdout.trim_end()).expect("stdout is JSON")
}

/// The C1 code of a run that failed: exit 1, nothing on stdout, one
/// `{"error":{"code","message"}}` line on stderr.
fn failure_code(out: &Output) -> String {
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
    let v: Value = serde_json::from_str(stderr.trim_end()).expect("stderr is C1 JSON");
    assert!(v["error"]["message"].is_string(), "{v}");
    v["error"]["code"].as_str().expect("C1 code").to_string()
}

fn keys(v: &Value) -> BTreeSet<&str> {
    v.as_object().unwrap().keys().map(|k| k.as_str()).collect()
}

fn path_of(v: &Value) -> PathBuf {
    PathBuf::from(v.as_str().unwrap_or_else(|| panic!("a path string: {v}")))
}

fn assert_hex_sha256(v: &Value) {
    let s = v.as_str().unwrap();
    assert_eq!(s.len(), 64, "{s}");
    assert!(
        s.chars()
            .all(|c| c.is_ascii_digit() || ('a'..='f').contains(&c)),
        "{s}"
    );
}

/// A created file's name: `<label>-<YYYYMMDDTHHMMSSZ>-<vault_id>.memex.zip`.
fn assert_backup_name(name: &str, vault_id: &str) {
    let rest = name
        .strip_prefix(&format!("{LABEL}-"))
        .unwrap_or_else(|| panic!("label first: {name}"));
    let stamp = rest
        .strip_suffix(&format!("-{vault_id}.memex.zip"))
        .unwrap_or_else(|| panic!("vault_id last: {name}"));
    let b = stamp.as_bytes();
    assert!(
        b.len() == 16
            && b[8] == b'T'
            && b[15] == b'Z'
            && b[..8].iter().chain(&b[9..15]).all(u8::is_ascii_digit),
        "timestamp YYYYMMDDTHHMMSSZ: {stamp}"
    );
}

// ---------------------------------------------------------------------------
// Success: the req 17 lines
// ---------------------------------------------------------------------------

#[test]
fn memex_backup_prints_the_created_line_with_absolute_paths_and_exits_0() {
    let fx = Fx::new();
    let old = fx.seed_backup("20200101T000000Z");
    // --dest relative to the working directory: the printed paths are
    // absolute anyway.
    let out = memex_in(
        Some(&fx.root),
        &[
            "backup",
            "--vault",
            fx.v(),
            "--dest",
            "My Drive",
            "--keep",
            "1",
        ],
    );
    let line = success_line(&out);

    assert_eq!(
        keys(&line),
        BTreeSet::from([
            "result",
            "vault_id",
            "file",
            "bytes",
            "fingerprint",
            "removed"
        ]),
        "{line}"
    );
    assert_eq!(line["result"], json!("created"));
    assert_eq!(line["vault_id"], json!(fx.vault_id));
    let file = path_of(&line["file"]);
    assert!(file.is_absolute(), "{}", file.display());
    assert_eq!(
        file.parent(),
        Some(fx.dest.as_path()),
        "file is in My Drive"
    );
    let name = file.file_name().unwrap().to_str().unwrap().to_string();
    assert_backup_name(&name, &fx.vault_id);
    assert_eq!(
        line["bytes"],
        json!(fs::metadata(&file).expect("the file exists").len())
    );
    assert_hex_sha256(&line["fingerprint"]);
    assert_eq!(line["removed"], json!([old.to_str().unwrap()]));
    assert!(!old.exists(), "retention removed the older backup");
    assert_eq!(fx.backups(), BTreeSet::from([name.clone()]));

    let recorded = state::destination_state(&fx.vault, &fx.dest).expect("recorded");
    assert_eq!(recorded.last_result, "created");
    assert_eq!(recorded.last_file, Some(name));
    assert_eq!(
        recorded.last_fingerprint.as_deref(),
        line["fingerprint"].as_str(),
        "printed = recorded"
    );
    assert_eq!(
        Some(json!(recorded.last_bytes)),
        Some(line["bytes"].clone())
    );
}

/// `backup.json` of the zip at `file`, read with the system `unzip` (this
/// crate has no zip dependency).
fn backup_json_of(file: &Path) -> Value {
    let out = Command::new("/usr/bin/unzip")
        .args(["-p"])
        .arg(file)
        .arg("backup.json")
        .output()
        .expect("spawn unzip");
    assert!(out.status.success(), "unzip -p {}: {out:?}", file.display());
    serde_json::from_slice(&out.stdout).expect("backup.json is JSON")
}

/// Req 3: the CLI is a local backup, so `backup.json` says `source: "local"`,
/// and its fingerprint is the one printed and recorded.
#[test]
fn memex_backup_writes_source_local_and_the_printed_fingerprint_into_backup_json() {
    let fx = Fx::new();
    let line = success_line(&memex(&["backup", "--vault", fx.v(), "--dest", fx.d()]));
    let bj = backup_json_of(&path_of(&line["file"]));

    assert_eq!(bj["source"], json!("local"), "{bj}");
    assert_eq!(
        bj["fingerprint"], line["fingerprint"],
        "printed = in the zip"
    );
    assert_eq!(bj["vault_id"], json!(fx.vault_id));
    let recorded = state::destination_state(&fx.vault, &fx.dest).expect("recorded");
    assert_eq!(
        recorded.last_fingerprint.as_deref(),
        bj["fingerprint"].as_str(),
        "recorded = in the zip"
    );
}

#[test]
fn memex_backup_if_changed_prints_unchanged_with_the_absolute_last_file() {
    let fx = Fx::new();
    let first = success_line(&memex(&["backup", "--vault", fx.v(), "--dest", fx.d()]));
    assert_eq!(first["result"], json!("created"));
    let listing = fx.backups();

    let out = memex(&[
        "backup",
        "--vault",
        fx.v(),
        "--dest",
        fx.d(),
        "--if-changed",
    ]);
    let line = success_line(&out);
    assert_eq!(
        keys(&line),
        BTreeSet::from(["result", "vault_id", "fingerprint", "last_file"]),
        "{line}"
    );
    assert_eq!(line["result"], json!("unchanged"));
    assert_eq!(line["vault_id"], json!(fx.vault_id));
    assert_eq!(line["fingerprint"], first["fingerprint"]);
    assert_eq!(line["last_file"], first["file"], "absolute last_file");
    assert!(path_of(&line["last_file"]).is_absolute());
    assert_eq!(fx.backups(), listing, "no new file");
    let recorded = state::destination_state(&fx.vault, &fx.dest).unwrap();
    assert_eq!(recorded.last_result, "unchanged");
}

#[test]
fn memex_backup_if_changed_on_a_new_destination_creates_a_file() {
    let fx = Fx::new();
    let line = success_line(&memex(&[
        "backup",
        "--vault",
        fx.v(),
        "--dest",
        fx.d(),
        "--if-changed",
    ]));
    assert_eq!(line["result"], json!("created"));
    assert!(path_of(&line["file"]).exists());
}

#[test]
fn memex_backup_keep_defaults_to_30() {
    let fx = Fx::new();
    let mut seeded = Vec::new();
    for day in 1..=30 {
        seeded.push(fx.seed_backup(&format!("202001{day:02}T000000Z")));
    }
    let line = success_line(&memex(&["backup", "--vault", fx.v(), "--dest", fx.d()]));
    assert_eq!(line["removed"], json!([seeded[0].to_str().unwrap()]));
    assert_eq!(fx.backups().len(), 30);
}

// ---------------------------------------------------------------------------
// Failure: one C1 line, exit 1
// ---------------------------------------------------------------------------

#[test]
fn memex_backup_failure_prints_its_c1_code_on_stderr_and_exits_1() {
    let fx = Fx::new();
    let missing = fx.root.join("No Such Folder");
    let inside = fx.vault.join("backups");
    fs::create_dir(&inside).unwrap();
    let cases: [(&str, &Path, &str); 2] = [
        ("missing dest", &missing, "backup_destination_unavailable"),
        (
            "dest inside the vault",
            &inside,
            "backup_destination_inside_vault",
        ),
    ];
    for (case, dest, code) in cases {
        let out = memex(&[
            "backup",
            "--vault",
            fx.v(),
            "--dest",
            dest.to_str().unwrap(),
        ]);
        assert_eq!(failure_code(&out), code, "{case}");
        let recorded =
            state::destination_state(&fx.vault, dest).unwrap_or_else(|| panic!("{case}: recorded"));
        assert_eq!(recorded.last_result, code, "{case}");
    }
    assert!(!missing.exists(), "the destination is never created");
}

#[test]
fn memex_backup_of_a_missing_vault_is_internal_and_creates_nothing() {
    let fx = Fx::new();
    let missing = fx.root.join("no such vault");
    let out = memex(&[
        "backup",
        "--vault",
        missing.to_str().unwrap(),
        "--dest",
        fx.d(),
    ]);
    assert_eq!(failure_code(&out), "internal");
    assert!(!missing.exists());
    assert!(fs::read_dir(&fx.dest).unwrap().next().is_none());
}

// ---------------------------------------------------------------------------
// req 17a: a closed stdout skips nothing
// ---------------------------------------------------------------------------

#[test]
fn memex_backup_with_stdout_closed_still_finishes_file_retention_and_state() {
    let fx = Fx::new();
    let old = fx.seed_backup("20200101T000000Z");
    // stdout is a pipe whose reader is already gone (the app quit).
    let (reader, writer) = std::io::pipe().unwrap();
    drop(reader);
    let status = Command::new(env!("CARGO_BIN_EXE_memex"))
        .args(["backup", "--vault", fx.v(), "--dest", fx.d(), "--keep", "1"])
        .stdout(Stdio::from(writer))
        .stderr(Stdio::piped())
        .status()
        .expect("spawn memex");
    assert!(
        status.success(),
        "a closed stdout is not a failure: {status:?}"
    );

    let backups = fx.backups();
    assert_eq!(backups.len(), 1, "the new file is there: {backups:?}");
    let name = backups.into_iter().next().unwrap();
    assert_backup_name(&name, &fx.vault_id);
    assert!(!old.exists(), "retention ran");
    let partials: Vec<_> = fs::read_dir(&fx.dest)
        .unwrap()
        .map(|e| e.unwrap().file_name().to_string_lossy().into_owned())
        .filter(|n| n.ends_with(".partial"))
        .collect();
    assert!(partials.is_empty(), "renamed, not left as a partial");
    let recorded = state::destination_state(&fx.vault, &fx.dest).expect("state written");
    assert_eq!(recorded.last_result, "created");
    assert_eq!(recorded.last_file, Some(name.clone()));
    assert_eq!(
        recorded.last_bytes,
        Some(fs::metadata(fx.dest.join(&name)).unwrap().len())
    );
}
