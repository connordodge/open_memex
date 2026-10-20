//! The vault server's access token (req 4, 5; D7).
//!
//! `MEMEX_ACCESS_TOKEN` wins over `<root>/.memex/access-token`; both are
//! trimmed, and an empty token is a startup error. With neither, 256 random
//! bits are written, hex-encoded, to a new `0600` token file. The token is
//! never read from argv and never printed.

use std::ffi::OsString;
use std::fs::OpenOptions;
use std::io::{ErrorKind, Write};
use std::os::unix::fs::OpenOptionsExt;
use std::path::{Path, PathBuf};

use anyhow::{Context, Result};

use crate::cli::InvalidArgument;

/// The env var that supplies the token.
pub const TOKEN_ENV: &str = "MEMEX_ACCESS_TOKEN";

/// Random bytes in a generated token (256 bits).
const TOKEN_BYTES: usize = 32;

/// `<root>/.memex/access-token`.
pub fn token_path(root: &Path) -> PathBuf {
    root.join(".memex").join("access-token")
}

/// The token the server accepts. No `Debug`, so it can't be printed by
/// accident.
pub struct ResolvedToken {
    /// The trimmed, non-empty token.
    pub token: String,
    /// The token file, when this call generated it (its path is printed once).
    pub generated: Option<PathBuf>,
}

/// Resolves the token for vault root `root` from `env` (the value of
/// [`TOKEN_ENV`], if set) or the token file, generating the file when neither
/// exists. An empty or whitespace-only token from either source is an error
/// and never leads to a generated file; an existing file is never rewritten.
pub fn resolve(root: &Path, env: Option<OsString>) -> Result<ResolvedToken> {
    if let Some(value) = env {
        let value = value
            .into_string()
            .map_err(|_| InvalidArgument(format!("{TOKEN_ENV} is not valid UTF-8")))?;
        let token = value.trim();
        if token.is_empty() {
            return Err(InvalidArgument(format!("{TOKEN_ENV} is set but empty")).into());
        }
        return Ok(ResolvedToken {
            token: token.to_string(),
            generated: None,
        });
    }

    let path = token_path(root);
    match std::fs::read_to_string(&path) {
        Ok(contents) => from_file(&path, &contents),
        Err(e) if e.kind() == ErrorKind::NotFound => generate(&path),
        Err(e) => Err(e).with_context(|| format!("read access token file {}", path.display())),
    }
}

fn from_file(path: &Path, contents: &str) -> Result<ResolvedToken> {
    let token = contents.trim();
    if token.is_empty() {
        return Err(InvalidArgument(format!(
            "access token file {} is empty; put a token in it or delete it to generate one",
            path.display()
        ))
        .into());
    }
    Ok(ResolvedToken {
        token: token.to_string(),
        generated: None,
    })
}

/// The permission bits of the token file at `path` when its group or others
/// may read it, else `None` (also when it can't be read).
pub fn readable_by_others(path: &Path) -> Option<u32> {
    use std::os::unix::fs::PermissionsExt;
    let mode = std::fs::metadata(path).ok()?.permissions().mode() & 0o777;
    (mode & 0o044 != 0).then_some(mode)
}

/// Writes a fresh token to `path` with mode `0600`. The token is written and
/// synced to a unique temp file beside `path`, then hard-linked to `path`,
/// which creates `path` only if it is absent, so `path` never exists
/// half-written. If another process created `path` first (or anything, even
/// a dangling symlink, is already there), that file's token is used instead.
/// A temp file this call created is always removed.
fn generate(path: &Path) -> Result<ResolvedToken> {
    let dir = path
        .parent()
        .context("the access token path has no parent directory")?;
    std::fs::create_dir_all(dir).with_context(|| format!("create {}", dir.display()))?;
    let token = random_hex(TOKEN_BYTES)?;
    let tmp = dir.join(format!(".access-token.{}.tmp", random_hex(8)?));
    if let Err(e) = write_new(&tmp, &token) {
        // `AlreadyExists` here means `tmp` is someone else's: leave it.
        if e.kind() != ErrorKind::AlreadyExists {
            let _ = std::fs::remove_file(&tmp);
        }
        return Err(e).with_context(|| format!("write access token file {}", tmp.display()));
    }
    let linked = std::fs::hard_link(&tmp, path);
    let _ = std::fs::remove_file(&tmp);
    match linked {
        Ok(()) => Ok(ResolvedToken {
            token,
            generated: Some(path.to_path_buf()),
        }),
        Err(e) if e.kind() == ErrorKind::AlreadyExists => {
            let contents = std::fs::read_to_string(path)
                .with_context(|| format!("read access token file {}", path.display()))?;
            from_file(path, &contents)
        }
        Err(e) => Err(e).with_context(|| format!("create access token file {}", path.display())),
    }
}

/// Creates `tmp` (which must not exist) with mode `0600` and writes
/// `token` and a newline to it, synced to disk.
fn write_new(tmp: &Path, token: &str) -> std::io::Result<()> {
    let mut file = OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(tmp)?;
    file.write_all(format!("{token}\n").as_bytes())?;
    file.sync_all()
}

/// `len` bytes from the OS random source, lower-case hex.
fn random_hex(len: usize) -> Result<String> {
    let mut bytes = vec![0u8; len];
    getrandom::fill(&mut bytes).map_err(|e| anyhow::anyhow!("read the OS random source: {e}"))?;
    Ok(bytes.iter().map(|b| format!("{b:02x}")).collect())
}
