use std::path::PathBuf;
use std::sync::Arc;

use anyhow::{Context, Result};
use clap::{Parser, Subcommand};
use memex_core::indexer;
use memex_core::notes::{create_note, list_notes, CreateNote};
use memex_core::tags;
use memex_core::Vault;
use rmcp::transport::stdio;
use rmcp::ServiceExt;
use tracing_subscriber::EnvFilter;

use memex_mcp::state::{build_default_embedder, AppState};
use memex_mcp::tools;

#[derive(Parser, Debug)]
#[command(name = "memex", version, about = "Open Memex — local-first AI-native notes")]
struct Cli {
    #[command(subcommand)]
    command: Commands,
}

#[derive(Subcommand, Debug)]
enum Commands {
    /// Create a new vault at <path>.
    Init {
        /// Vault directory (created if it doesn't exist).
        path: PathBuf,
    },
    /// Append a note to a vault from CLI input. Body comes from stdin.
    Add {
        /// Vault directory.
        #[arg(long)]
        vault: PathBuf,
        /// Title (default: derived from first line).
        #[arg(long)]
        title: Option<String>,
        /// Comma-separated tags.
        #[arg(long, value_delimiter = ',')]
        tags: Vec<String>,
        /// Use real embeddings (downloads BGE-small on first call).
        #[arg(long)]
        with_embeddings: bool,
    },
    /// List notes in a vault.
    Ls {
        /// Vault directory.
        #[arg(long)]
        vault: PathBuf,
        /// Max notes to show.
        #[arg(long, default_value = "20")]
        limit: i64,
    },
    /// Run as an MCP server over stdio.
    Serve {
        /// Vault directory.
        #[arg(long)]
        vault: PathBuf,
        /// Use real embeddings (downloads BGE-small on first search/index).
        #[arg(long)]
        with_embeddings: bool,
        /// Log level filter (default: info). Logs go to <vault>/.memex/mcp.log.
        #[arg(long, default_value = "info")]
        log_level: String,
    },
}

#[tokio::main]
async fn main() -> Result<()> {
    let cli = Cli::parse();
    match cli.command {
        Commands::Init { path } => cmd_init(path),
        Commands::Add {
            vault,
            title,
            tags,
            with_embeddings,
        } => cmd_add(vault, title, tags, with_embeddings).await,
        Commands::Ls { vault, limit } => cmd_ls(vault, limit),
        Commands::Serve {
            vault,
            with_embeddings,
            log_level,
        } => cmd_serve(vault, with_embeddings, log_level).await,
    }
}

fn cmd_init(path: PathBuf) -> Result<()> {
    let absolute = make_absolute(&path)?;
    let vault = Vault::create(&absolute).context("create vault")?;
    println!("Initialized vault");
    println!("  path:        {}", absolute.display());
    println!("  vault_id:    {}", vault.vault_id());
    println!("  schema_ver:  {}", vault.schema_version());
    Ok(())
}

async fn cmd_add(
    vault_path: PathBuf,
    title: Option<String>,
    tag_list: Vec<String>,
    with_embeddings: bool,
) -> Result<()> {
    use std::io::Read;
    let absolute = make_absolute(&vault_path)?;
    let mut buf = String::new();
    std::io::stdin()
        .read_to_string(&mut buf)
        .context("read note body from stdin")?;
    if buf.trim().is_empty() {
        anyhow::bail!("stdin was empty — nothing to add");
    }

    let mut vault = Vault::open(&absolute).context("open vault")?;
    let note = create_note(
        &mut vault,
        CreateNote {
            title,
            content_md: buf.clone(),
            frontmatter: None,
        },
    )?;
    for t in &tag_list {
        tags::add_tag(&vault, note.id.as_str(), t)?;
    }

    let embedder = if with_embeddings {
        Some(build_default_embedder(&absolute))
    } else {
        None
    };
    indexer::reindex_note(
        vault.connection_mut(),
        note.id.as_str(),
        &buf,
        embedder.as_deref(),
    )?;

    println!("Created note");
    println!("  note_id: {}", note.id);
    println!("  title:   {}", note.title);
    if !tag_list.is_empty() {
        println!("  tags:    {}", tag_list.join(", "));
    }
    Ok(())
}

fn cmd_ls(vault_path: PathBuf, limit: i64) -> Result<()> {
    let absolute = make_absolute(&vault_path)?;
    let vault = Vault::open(&absolute)?;
    let listed = list_notes(&vault, limit)?;
    if listed.is_empty() {
        println!("(empty vault)");
        return Ok(());
    }
    for n in listed {
        println!("{}  {}", n.id, n.title);
    }
    Ok(())
}

async fn cmd_serve(
    vault_path: PathBuf,
    with_embeddings: bool,
    log_level: String,
) -> Result<()> {
    let absolute = make_absolute(&vault_path)?;
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

    let service = memex
        .serve(stdio())
        .await
        .context("start MCP service")?;
    service
        .waiting()
        .await
        .context("MCP service exited unexpectedly")?;
    Ok(())
}

fn make_absolute(p: &PathBuf) -> Result<PathBuf> {
    if p.is_absolute() {
        Ok(p.clone())
    } else {
        Ok(std::env::current_dir()?.join(p))
    }
}
