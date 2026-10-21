//! `memex serve`: one of three modes (req 6, 7; D3).
//!
//! - `--vault <path>`: an MCP server over stdio for one local vault, logging
//!   to `<vault>/.memex/mcp.log`.
//! - `--root <dir> --listen <host:port>`: the vault server over HTTP.
//! - `--remote <url>`: a stdio bridge to a hosted vault (#95).
//!
//! Flags from different modes, or no mode at all, are clap usage errors
//! (exit 2). No flag takes the access token: it comes from
//! `MEMEX_ACCESS_TOKEN` or the token file, never argv.

use std::path::PathBuf;
use std::sync::Arc;

use anyhow::{Context, Result};
use clap::{ArgGroup, Args};
use memex_core::{SystemClock, Vault};
use rmcp::transport::stdio;
use rmcp::ServiceExt;
use tracing_subscriber::EnvFilter;

use super::{CodedError, InvalidArgument};
use crate::server;
use crate::server::bridge::{self, BridgeOptions};
use crate::server::token::TOKEN_ENV;
use crate::state::{build_default_embedder, AppState};
use crate::tools;

/// The log level when `--log-level` is not given.
const DEFAULT_LOG_LEVEL: &str = "info";

#[derive(Args, Debug)]
#[command(group(
    ArgGroup::new("mode")
        .required(true)
        .args(["vault", "root", "remote"])
))]
pub struct ServeArgs {
    /// Serve this vault directory over stdio (MCP).
    #[arg(long, conflicts_with_all = ["root", "listen", "remote"])]
    pub vault: Option<PathBuf>,
    /// Serve every vault in this directory over HTTP (needs --listen).
    #[arg(long, requires = "listen", conflicts_with_all = ["vault", "remote"])]
    pub root: Option<PathBuf>,
    /// Address the vault server listens on, as <host:port> (needs --root).
    #[arg(long, requires = "root", conflicts_with_all = ["vault", "remote"])]
    pub listen: Option<String>,
    /// Bridge stdio MCP to a hosted vault's /mcp URL,
    /// <server-url>/vaults/<name>/mcp (token from MEMEX_ACCESS_TOKEN).
    #[arg(
        long,
        value_parser = remote_url,
        conflicts_with_all = ["vault", "root", "listen", "with_embeddings", "log_level"]
    )]
    pub remote: Option<String>,
    /// Use real embeddings (downloads BGE-small on first search/index).
    #[arg(long)]
    pub with_embeddings: bool,
    /// Log level filter (default: info). Logs go to <vault>/.memex/mcp.log,
    /// or <root>/.memex/server.log for the vault server.
    #[arg(long)]
    pub log_level: Option<String>,
}

/// Runs the chosen mode.
pub async fn run(args: ServeArgs) -> Result<()> {
    let log_level = args
        .log_level
        .unwrap_or_else(|| DEFAULT_LOG_LEVEL.to_string());
    match (args.vault, args.root, args.listen, args.remote) {
        (Some(vault), ..) => serve_stdio(vault, args.with_embeddings, log_level).await,
        (None, Some(root), Some(listen), None) => {
            server::run(server::RunOptions {
                root,
                listen,
                with_embeddings: args.with_embeddings,
                log_level,
            })
            .await
        }
        (None, None, None, Some(remote)) => serve_remote(remote).await,
        // clap's mode group and conflicts rule out every other combination.
        _ => Err(InvalidArgument(
            "memex serve: pass --vault, --root with --listen, or --remote".into(),
        )
        .into()),
    }
}

/// The `--remote` value parser: a URL whose path is exactly
/// `/vaults/<name>/mcp`. Anything else is a clap usage error (exit 2).
fn remote_url(raw: &str) -> Result<String, String> {
    bridge::check_remote_url(raw).map(|()| raw.to_string())
}

/// `memex serve --remote <url>`: the stdio bridge, with the token from
/// `MEMEX_ACCESS_TOKEN` (trimmed). Unset, empty or whitespace-only is C1
/// `access_token_missing`, before any request.
async fn serve_remote(url: String) -> Result<()> {
    let token = match std::env::var(TOKEN_ENV) {
        Ok(value) => value.trim().to_string(),
        Err(std::env::VarError::NotPresent) => String::new(),
        Err(std::env::VarError::NotUnicode(_)) => {
            return Err(InvalidArgument(format!("{TOKEN_ENV} is not valid UTF-8")).into())
        }
    };
    if token.is_empty() {
        return Err(CodedError::new(
            "access_token_missing",
            format!("set {TOKEN_ENV} to the vault server's access token"),
        )
        .into());
    }
    bridge::run(
        BridgeOptions {
            url,
            token,
            clock: Arc::new(SystemClock),
        },
        stdin_reader(),
        tokio::io::stdout(),
    )
    .await
}

/// The process's stdin as an `AsyncRead`, read on a plain thread.
/// `tokio::io::stdin()` reads on the blocking pool, and a read that never
/// returns would hold up runtime shutdown when the bridge exits on a 401
/// while the client keeps stdin open.
fn stdin_reader() -> tokio::io::DuplexStream {
    use std::io::Read;
    use tokio::io::AsyncWriteExt;

    let (reader, mut writer) = tokio::io::duplex(64 * 1024);
    let runtime = tokio::runtime::Handle::current();
    std::thread::spawn(move || {
        let mut stdin = std::io::stdin().lock();
        let mut buf = vec![0u8; 64 * 1024];
        loop {
            let n = match stdin.read(&mut buf) {
                Ok(0) => break,
                Ok(n) => n,
                Err(e) if e.kind() == std::io::ErrorKind::Interrupted => continue,
                Err(_) => break,
            };
            if runtime.block_on(writer.write_all(&buf[..n])).is_err() {
                break;
            }
        }
        // Dropping the writer is EOF for the bridge.
    });
    reader
}

/// `memex serve --vault <path>`: the stdio MCP server, as before the vault
/// server existed.
async fn serve_stdio(vault_path: PathBuf, with_embeddings: bool, log_level: String) -> Result<()> {
    let absolute = std::path::absolute(&vault_path).context("resolve --vault")?;
    let log_dir = absolute.join(".memex");
    std::fs::create_dir_all(&log_dir).context("create .memex log dir")?;
    let file_appender = tracing_appender::rolling::daily(&log_dir, "mcp.log");
    let (nonblocking, _guard) = tracing_appender::non_blocking(file_appender);
    let _ = tracing_subscriber::fmt()
        .with_env_filter(EnvFilter::new(log_level))
        .with_writer(nonblocking)
        .with_ansi(false)
        .try_init();

    tracing::info!(?absolute, with_embeddings, "starting memex-mcp");

    let vault = Vault::open(&absolute).context("open vault")?;
    let embedder = if with_embeddings {
        Some(build_default_embedder(&absolute))
    } else {
        None
    };
    let state = Arc::new(AppState::new(vault, absolute, embedder));
    let memex = tools::Memex::new(state);

    let service = memex.serve(stdio()).await.context("start MCP service")?;
    service
        .waiting()
        .await
        .context("MCP service exited unexpectedly")?;
    Ok(())
}
