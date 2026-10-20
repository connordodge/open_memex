//! WI #71 (R0a): vault-server startup and the access token (req 4, 5, 8;
//! D7). Drives the built `memex` binary; the token environment is set on
//! the child only.
//!
//! - AC 3: startup failures exit 1 with exactly one C1 line on stderr and
//!   leave nothing listening.
//! - AC 4: `MEMEX_ACCESS_TOKEN` wins over `<root>/.memex/access-token`;
//!   both are trimmed.
//! - AC 5: with neither, a 256-bit token is generated into a `0600` file
//!   whose absolute path is printed once; the token itself never is.

#[path = "support/server.rs"]
mod server;

use std::net::{SocketAddr, TcpListener as StdTcpListener};
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::time::Duration;

use regex::Regex;
use serde_json::Value;

use server::{free_port, get, ServeChild, ServeCommand, TOKEN_ENV};

const LIMIT: Duration = Duration::from_secs(30);

fn token_file(root: &Path) -> PathBuf {
    root.join(".memex").join("access-token")
}

fn write_token_file(root: &Path, contents: &str) {
    std::fs::create_dir_all(root.join(".memex")).unwrap();
    std::fs::write(token_file(root), contents).unwrap();
}

/// `memex serve --root <root> --listen 127.0.0.1:<free port>`.
fn vault_server(root: &Path) -> (ServeCommand, SocketAddr) {
    let addr: SocketAddr = format!("127.0.0.1:{}", free_port()).parse().unwrap();
    let cmd = ServeCommand::new(&[
        "--root",
        root.to_str().unwrap(),
        "--listen",
        &addr.to_string(),
    ]);
    (cmd, addr)
}

async fn started(cmd: ServeCommand, addr: SocketAddr) -> ServeChild {
    let mut child = cmd.spawn();
    child.wait_ready(addr).await;
    child
}

async fn info_status(addr: SocketAddr, token: &str) -> u16 {
    get(
        &format!("http://{addr}/api/v1/info"),
        Some(&format!("Bearer {token}")),
    )
    .await
    .status
}

// ---------- AC 3: startup failures ----------

#[test]
fn startup_failures_exit_1_with_one_c1_line_and_nothing_listening() {
    let dir = tempfile::tempdir().unwrap();
    let missing = dir.path().join("missing-root");
    let regular_file = dir.path().join("root-is-a-file");
    std::fs::write(&regular_file, "not a directory").unwrap();
    let empty_env_root = dir.path().join("empty-env");
    std::fs::create_dir(&empty_env_root).unwrap();
    let blank_env_root = dir.path().join("blank-env");
    std::fs::create_dir(&blank_env_root).unwrap();
    let blank_file_root = dir.path().join("blank-file");
    std::fs::create_dir(&blank_file_root).unwrap();
    write_token_file(&blank_file_root, "  \n\t \n");
    let busy_root = dir.path().join("busy");
    std::fs::create_dir(&busy_root).unwrap();
    let occupied = StdTcpListener::bind("127.0.0.1:0").unwrap();
    let busy_addr = occupied.local_addr().unwrap().to_string();

    let good_env = Some("startup-env-token-9a8b7c");
    // (case, root, listen, MEMEX_ACCESS_TOKEN)
    let free = || format!("127.0.0.1:{}", free_port());
    let cases: Vec<(&str, &Path, String, Option<&str>)> = vec![
        ("--root does not exist", &missing, free(), good_env),
        ("--root is a regular file", &regular_file, free(), good_env),
        (
            "MEMEX_ACCESS_TOKEN is empty",
            &empty_env_root,
            free(),
            Some(""),
        ),
        (
            "MEMEX_ACCESS_TOKEN is whitespace",
            &blank_env_root,
            free(),
            Some(" \t\n "),
        ),
        (
            "access-token file is whitespace",
            &blank_file_root,
            free(),
            None,
        ),
        (
            "--listen address in use",
            &busy_root,
            busy_addr.clone(),
            good_env,
        ),
    ];

    for (case, root, listen, env) in cases {
        let mut cmd = ServeCommand::new(&["--root", root.to_str().unwrap(), "--listen", &listen]);
        if let Some(value) = env {
            cmd = cmd.env(TOKEN_ENV, value);
        }
        let out = cmd.run_within(LIMIT);
        assert_eq!(out.code, Some(1), "{case}: exit 1\n{}", out.describe());
        let lines = out.stderr_lines();
        assert_eq!(
            lines.len(),
            1,
            "{case}: exactly one stderr line\n{}",
            out.describe()
        );
        let v: Value = serde_json::from_str(lines[0])
            .unwrap_or_else(|e| panic!("{case}: stderr is C1 JSON ({e})\n{}", out.describe()));
        assert!(
            v["error"]["code"].is_string() && v["error"]["message"].is_string(),
            "{case}: C1 body {v}"
        );
        if let Some(token) = good_env {
            assert!(
                !out.stderr.contains(token),
                "{case}: the token is never printed\n{}",
                out.describe()
            );
        }
        if listen != busy_addr {
            assert!(
                std::net::TcpStream::connect(&listen).is_err(),
                "{case}: nothing listens on {listen}"
            );
        }
    }

    assert!(!missing.exists(), "a missing --root is not created");
    assert_eq!(
        std::fs::read_to_string(&regular_file).unwrap(),
        "not a directory",
        "a file --root is untouched"
    );
    for root in [&empty_env_root, &blank_env_root] {
        assert!(
            !token_file(root).exists(),
            "an empty MEMEX_ACCESS_TOKEN is an error, not a reason to generate a token file"
        );
    }
    assert_eq!(
        std::fs::read_to_string(token_file(&blank_file_root)).unwrap(),
        "  \n\t \n",
        "a blank token file is not overwritten"
    );
    drop(occupied);
}

// ---------- AC 4: token source and trimming ----------

#[tokio::test]
async fn env_token_wins_and_the_file_token_then_gets_401() {
    let dir = tempfile::tempdir().unwrap();
    write_token_file(dir.path(), "file-token-4c1d2e3f\n");
    let (cmd, addr) = vault_server(dir.path());
    let child = started(cmd.env(TOKEN_ENV, "env-token-7a6b5c4d"), addr).await;

    assert_eq!(info_status(addr, "env-token-7a6b5c4d").await, 200);
    assert_eq!(info_status(addr, "file-token-4c1d2e3f").await, 401);
    assert_eq!(
        std::fs::read_to_string(token_file(dir.path())).unwrap(),
        "file-token-4c1d2e3f\n",
        "the file is left as it was"
    );
    drop(child);
}

#[tokio::test]
async fn file_token_authenticates_when_the_env_is_unset() {
    let dir = tempfile::tempdir().unwrap();
    write_token_file(dir.path(), "file-only-token-0e9d8c7b");
    let (cmd, addr) = vault_server(dir.path());
    let child = started(cmd, addr).await;

    assert_eq!(info_status(addr, "file-only-token-0e9d8c7b").await, 200);
    assert_eq!(info_status(addr, "file-only-token-0e9d8c7").await, 401);
    assert_eq!(info_status(addr, "some-other-token").await, 401);
    let stderr = child.stderr();
    assert!(
        !stderr.contains("file-only-token-0e9d8c7b"),
        "the token is never printed: {stderr}"
    );
}

#[tokio::test]
async fn tokens_are_trimmed_from_the_env_and_the_file() {
    let dir = tempfile::tempdir().unwrap();
    let env_root = dir.path().join("env");
    std::fs::create_dir(&env_root).unwrap();
    let (cmd, addr) = vault_server(&env_root);
    let child = started(cmd.env(TOKEN_ENV, "  tok-env-1f2e\n"), addr).await;
    assert_eq!(info_status(addr, "tok-env-1f2e").await, 200, "env trimmed");
    drop(child);

    let file_root = dir.path().join("file");
    std::fs::create_dir(&file_root).unwrap();
    write_token_file(&file_root, "\t  tok-file-3d4c \n\n");
    let (cmd, addr) = vault_server(&file_root);
    let child = started(cmd, addr).await;
    assert_eq!(
        info_status(addr, "tok-file-3d4c").await,
        200,
        "file trimmed"
    );
    drop(child);
}

// ---------- AC 5: token generation ----------

/// Every `<abs path>/.memex/access-token` printed in `stderr`.
fn printed_token_paths(stderr: &str) -> Vec<String> {
    Regex::new(r"(/[^\s'`]*?/\.memex/access-token)")
        .unwrap()
        .captures_iter(stderr)
        .map(|c| c[1].to_string())
        .collect()
}

fn read_generated_token(root: &Path) -> String {
    let path = token_file(root);
    let mode = std::fs::metadata(&path)
        .unwrap_or_else(|e| panic!("token file {path:?} exists: {e}"))
        .permissions()
        .mode();
    assert_eq!(mode & 0o777, 0o600, "token file mode is 0600, got {mode:o}");
    let token = std::fs::read_to_string(&path).unwrap().trim().to_string();
    // 256 random bits: at least 43 characters even in unpadded base64.
    assert!(
        token.len() >= 43,
        "token carries 256 bits: {} chars",
        token.len()
    );
    assert!(
        token
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || "-_.~+/=".contains(c)),
        "token is safe in a Bearer header"
    );
    token
}

#[tokio::test]
async fn generated_token_file_is_0600_its_path_printed_once_and_the_token_never() {
    let dir = tempfile::tempdir().unwrap();
    let root = dir.path().join("root");
    std::fs::create_dir(&root).unwrap();
    let (cmd, addr) = vault_server(&root);
    let child = started(cmd, addr).await;

    assert!(root.join(".memex").is_dir(), "<root>/.memex/ is created");
    let token = read_generated_token(&root);
    let stderr = child.stderr();
    assert_eq!(
        stderr.matches("access-token").count(),
        1,
        "the token file is named exactly once: {stderr}"
    );
    let printed = printed_token_paths(&stderr);
    assert_eq!(printed.len(), 1, "one absolute path printed: {stderr}");
    assert_eq!(
        Path::new(&printed[0]).canonicalize().unwrap(),
        token_file(&root).canonicalize().unwrap(),
        "the printed path is the token file"
    );
    assert!(
        !stderr.contains(&token),
        "the token is never printed: {stderr}"
    );
    assert!(!child.stdout().contains(&token), "nor on stdout");

    assert_eq!(
        info_status(addr, &token).await,
        200,
        "the generated token works"
    );
    assert_eq!(info_status(addr, "not-the-generated-token").await, 401);
    drop(child);

    let other = dir.path().join("other-root");
    std::fs::create_dir(&other).unwrap();
    let (cmd, addr) = vault_server(&other);
    let child = started(cmd, addr).await;
    let other_token = read_generated_token(&other);
    assert_ne!(other_token, token, "a fresh root gets a fresh token");
    assert_eq!(info_status(addr, &other_token).await, 200);
    assert_eq!(info_status(addr, &token).await, 401);
    drop(child);
}

#[tokio::test]
async fn generated_token_is_kept_across_restarts() {
    let dir = tempfile::tempdir().unwrap();
    let (cmd, addr) = vault_server(dir.path());
    let child = started(cmd, addr).await;
    let token = read_generated_token(dir.path());
    drop(child);

    let (cmd, addr) = vault_server(dir.path());
    let child = started(cmd, addr).await;
    assert_eq!(
        read_generated_token(dir.path()),
        token,
        "an existing token file is never regenerated"
    );
    assert_eq!(info_status(addr, &token).await, 200);
    assert!(!child.stderr().contains(&token));
}

#[tokio::test]
async fn generated_token_path_is_absolute_for_a_relative_root() {
    let dir = tempfile::tempdir().unwrap();
    std::fs::create_dir(dir.path().join("rel-root")).unwrap();
    let addr: SocketAddr = format!("127.0.0.1:{}", free_port()).parse().unwrap();
    let cmd = ServeCommand::new(&["--root", "rel-root", "--listen", &addr.to_string()])
        .current_dir(dir.path());
    let child = started(cmd, addr).await;
    let stderr = child.stderr();
    let printed = printed_token_paths(&stderr);
    assert_eq!(printed.len(), 1, "one absolute path printed: {stderr}");
    assert!(Path::new(&printed[0]).is_absolute());
    assert_eq!(
        Path::new(&printed[0]).canonicalize().unwrap(),
        token_file(&dir.path().join("rel-root"))
            .canonicalize()
            .unwrap()
    );
}
