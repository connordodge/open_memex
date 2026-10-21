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
use memex_core::Vault;
use rmcp::transport::stdio;
use rmcp::ServiceExt;
use tracing_subscriber::EnvFilter;

use super::InvalidArgument;
use crate::server;
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
    /// Bridge stdio MCP to a hosted vault's /mcp URL.
    #[arg(
        long,
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
        (None, None, None, Some(_remote)) => super::not_implemented("serve --remote"),
        // clap's mode group and conflicts rule out every other combination.
        _ => Err(InvalidArgument(
            "memex serve: pass --vault, --root with --listen, or --remote".into(),
        )
        .into()),
    }
}

/// `memex serve --vault <path>`: the stdio MCP server, as before the vault
/// server existed.
async fn serve_stdio(vault_path: PathBuf, with_embeddings: bool, log_level: String) -> Result<()> {
    let absolute = std::path::absolute(&vault_path).context("resolve --vault")?;
    memex_core::fs_guard::check(&absolute)?;
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
