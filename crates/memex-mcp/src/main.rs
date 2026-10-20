use std::path::PathBuf;
use std::process::ExitCode;
use std::sync::Arc;

use anyhow::{Context, Result};
use clap::{Parser, Subcommand};
use memex_core::links::{self as core_links, LinkKind};
use memex_core::notes::{get_note as core_get_note, list_notes, NoteId};
use memex_core::{SystemClock, Vault};
use rmcp::transport::stdio;
use rmcp::ServiceExt;
use tracing_subscriber::EnvFilter;

use memex_mcp::cli::{self, InvalidArgument, Role};
use memex_mcp::ops;
use memex_mcp::state::{build_default_embedder, AppState};
use memex_mcp::tools;

#[derive(Parser, Debug)]
#[command(
    name = "memex",
    version,
    about = "Open Memex — local-first AI-native notes"
)]
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
        /// Note role, stored in frontmatter as `role`.
        #[arg(long, value_enum)]
        role: Option<Role>,
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
    /// Update an existing note. Body comes from stdin.
    Update {
        /// Vault directory.
        #[arg(long)]
        vault: PathBuf,
        /// Note id (ULID).
        #[arg(long)]
        note_id: String,
        /// Expected current version (optimistic concurrency).
        #[arg(long)]
        expected_version: i64,
        /// New title (optional; if omitted, keeps existing title).
        #[arg(long)]
        title: Option<String>,
        /// Skip the title-rename pass that rewrites `[[OldTitle]]` in linkers.
        #[arg(long)]
        no_rename_links: bool,
        /// Use real embeddings.
        #[arg(long)]
        with_embeddings: bool,
    },
    /// Print a single note as JSON to stdout.
    Get {
        /// Vault directory.
        #[arg(long)]
        vault: PathBuf,
        /// Note id (ULID).
        #[arg(long)]
        note_id: String,
        /// Include outgoing links + backlinks in the JSON output.
        #[arg(long)]
        include_links: bool,
    },
    /// Print outgoing + incoming links for a note as a tree.
    Links {
        /// Vault directory.
        #[arg(long)]
        vault: PathBuf,
        /// Note id (ULID).
        #[arg(long)]
        note_id: String,
        /// Direction: in, out, or both (default).
        #[arg(long, default_value = "both", value_parser = ["in", "out", "both"])]
        dir: String,
        /// Optional kind filter (e.g. `extends`, `inspired-by`).
        #[arg(long)]
        kind: Option<String>,
    },
    /// Add a wikilink from one note to another. Inserts into the source note's
    /// markdown per the destination rule and re-indexes.
    AddLink {
        /// Vault directory.
        #[arg(long)]
        vault: PathBuf,
        /// Source note id.
        #[arg(long)]
        from: String,
        /// Target note id.
        #[arg(long)]
        to: String,
        /// Kind. Built-in (`references`, `extends`, `contradicts`, `example-of`)
        /// or any user-defined kebab-case kind. Default: `references`.
        #[arg(long, default_value = "references")]
        kind: String,
        /// Optional display alias (used as the wikilink's `|alias` segment).
        #[arg(long)]
        label: Option<String>,
        /// Use real embeddings during the post-write reindex.
        #[arg(long)]
        with_embeddings: bool,
    },
    /// Rewrite the `kind` and/or `label` on an existing wikilink in place.
    UpdateLink {
        /// Vault directory.
        #[arg(long)]
        vault: PathBuf,
        /// Link id (ULID-style id from the `links` table).
        #[arg(long)]
        link_id: String,
        /// New kind. If omitted, kind is unchanged.
        #[arg(long)]
        kind: Option<String>,
        /// New label. If omitted, label is unchanged.
        #[arg(long)]
        label: Option<String>,
        /// Clear the label (overrides --label).
        #[arg(long)]
        clear_label: bool,
        /// Use real embeddings during the post-write reindex.
        #[arg(long)]
        with_embeddings: bool,
    },
    /// Canvas operations: create/list/get/rename/delete canvases and place,
    /// remove, or move notes on them.
    Canvas {
        #[command(subcommand)]
        action: CanvasAction,
    },
    /// Append text to a daily note. Text comes from TEXT or stdin.
    Append(cli::append::AppendArgs),
    /// Print an agent prompt's raw text.
    Prompt(cli::prompt::PromptArgs),
    /// Delete a note.
    Rm(cli::rm::RmArgs),
    /// Excerpt operations on topic notes.
    Excerpt(cli::excerpt::ExcerptArgs),
    /// Topic footer operations on daily notes.
    Footer(cli::footer::FooterArgs),
    /// Smart Folder operations.
    Folder(cli::folder::FolderArgs),
    /// Read or change vault settings.
    Settings(cli::settings::SettingsArgs),
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

#[derive(Subcommand, Debug)]
enum CanvasAction {
    /// Create a new canvas.
    New {
        #[arg(long)]
        vault: PathBuf,
        #[arg(long)]
        title: String,
    },
    /// List all canvases.
    Ls {
        #[arg(long)]
        vault: PathBuf,
    },
    /// Print one canvas as JSON.
    Get {
        #[arg(long)]
        vault: PathBuf,
        #[arg(long)]
        canvas_id: String,
    },
    /// Rename a canvas.
    Rename {
        #[arg(long)]
        vault: PathBuf,
        #[arg(long)]
        canvas_id: String,
        #[arg(long)]
        title: String,
        #[arg(long)]
        expected_version: i64,
    },
    /// Delete a canvas (cascades placements only).
    Rm {
        #[arg(long)]
        vault: PathBuf,
        #[arg(long)]
        canvas_id: String,
        #[arg(long)]
        expected_version: i64,
    },
    /// Place a note on a canvas at (x, y).
    Add {
        #[arg(long)]
        vault: PathBuf,
        #[arg(long)]
        canvas_id: String,
        #[arg(long)]
        note_id: String,
        #[arg(long, default_value = "0.0")]
        x: f64,
        #[arg(long, default_value = "0.0")]
        y: f64,
    },
    /// Remove a note's placement from a canvas.
    Remove {
        #[arg(long)]
        vault: PathBuf,
        #[arg(long)]
        canvas_id: String,
        #[arg(long)]
        note_id: String,
    },
    /// Move a placed node to new coordinates.
    Move {
        #[arg(long)]
        vault: PathBuf,
        #[arg(long)]
        canvas_id: String,
        #[arg(long)]
        note_id: String,
        #[arg(long)]
        x: f64,
        #[arg(long)]
        y: f64,
        #[arg(long)]
        z: Option<i64>,
    },
}

/// Runs one subcommand. Clap usage errors keep clap's output and exit 2; any
/// other failure prints one line of JSON on stderr and exits 1 (CONTRACTS C1).
#[tokio::main]
async fn main() -> ExitCode {
    let cli = Cli::parse();
    match dispatch(cli.command).await {
        Ok(()) => ExitCode::SUCCESS,
        Err(e) => {
            eprintln!("{}", cli::error_json(&e));
            ExitCode::FAILURE
        }
    }
}

async fn dispatch(command: Commands) -> Result<()> {
    match command {
        Commands::Init { path } => cmd_init(path),
        Commands::Add {
            vault,
            title,
            tags,
            role,
            with_embeddings,
        } => cmd_add(vault, title, tags, role, with_embeddings).await,
        Commands::Ls { vault, limit } => cmd_ls(vault, limit),
        Commands::Update {
            vault,
            note_id,
            expected_version,
            title,
            no_rename_links,
            with_embeddings,
        } => {
            cmd_update(
                vault,
                note_id,
                expected_version,
                title,
                no_rename_links,
                with_embeddings,
            )
            .await
        }
        Commands::Get {
            vault,
            note_id,
            include_links,
        } => cmd_get(vault, note_id, include_links),
        Commands::Links {
            vault,
            note_id,
            dir,
            kind,
        } => cmd_links(vault, note_id, dir, kind),
        Commands::AddLink {
            vault,
            from,
            to,
            kind,
            label,
            with_embeddings,
        } => cmd_add_link(vault, from, to, kind, label, with_embeddings).await,
        Commands::UpdateLink {
            vault,
            link_id,
            kind,
            label,
            clear_label,
            with_embeddings,
        } => cmd_update_link(vault, link_id, kind, label, clear_label, with_embeddings).await,
        Commands::Canvas { action } => cmd_canvas(action),
        Commands::Append(args) => cli::append::run(args),
        Commands::Prompt(args) => cli::prompt::run(args),
        Commands::Rm(args) => cli::rm::run(args),
        Commands::Excerpt(args) => cli::excerpt::run(args),
        Commands::Footer(args) => cli::footer::run(args),
        Commands::Folder(args) => cli::folder::run(args),
        Commands::Settings(args) => cli::settings::run(args),
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
    role: Option<Role>,
    with_embeddings: bool,
) -> Result<()> {
    use std::io::Read;
    let absolute = make_absolute(&vault_path)?;
    let mut buf = String::new();
    std::io::stdin()
        .read_to_string(&mut buf)
        .context("read note body from stdin")?;
    let input = ops::notes::AddInput {
        title,
        content_md: buf,
        tags: tag_list,
        role,
    };
    // C2.1: an empty body fails before the vault opens (a daily note may
    // start empty; its title defaults to today, local).
    input.validate()?;

    let mut vault = Vault::open(&absolute).context("open vault")?;
    let embedder = if with_embeddings {
        Some(build_default_embedder(&absolute))
    } else {
        None
    };
    let out = ops::notes::add(&mut vault, input, &SystemClock, embedder.as_deref())?;

    let first_line = if out.adopted {
        "Adopted note"
    } else {
        "Created note"
    };
    println!("{first_line}");
    println!("  note_id: {}", out.note_id);
    println!("  title:   {}", out.title);
    if !out.tags.is_empty() {
        println!("  tags:    {}", out.tags.join(", "));
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

async fn cmd_update(
    vault_path: PathBuf,
    note_id: String,
    expected_version: i64,
    title: Option<String>,
    no_rename_links: bool,
    with_embeddings: bool,
) -> Result<()> {
    use std::io::Read;
    let absolute = make_absolute(&vault_path)?;
    let mut buf = String::new();
    std::io::stdin()
        .read_to_string(&mut buf)
        .context("read note body from stdin")?;

    NoteId::parse(&note_id)?;
    let mut vault = Vault::open(&absolute).context("open vault")?;
    let embedder = if with_embeddings {
        Some(build_default_embedder(&absolute))
    } else {
        None
    };
    let input = ops::notes::UpdateInput {
        note_id,
        expected_version,
        title,
        content_md: buf,
        no_rename_links,
    };
    let out = ops::notes::update(&mut vault, input, &SystemClock, embedder.as_deref())?;
    println!("{}", serde_json::to_string(&out)?);
    Ok(())
}

fn cmd_get(vault_path: PathBuf, note_id: String, include_links: bool) -> Result<()> {
    let absolute = make_absolute(&vault_path)?;
    NoteId::parse(&note_id)?;
    let mut vault = Vault::open(&absolute)?;
    let input = ops::notes::GetInput {
        note_id,
        include_links,
    };
    let out = ops::notes::get(&mut vault, input, &SystemClock, None)?;
    // Through a `Value` so the keys print sorted, as they always have.
    println!("{}", serde_json::to_string(&serde_json::to_value(&out)?)?);
    Ok(())
}

fn cmd_links(
    vault_path: PathBuf,
    note_id: String,
    dir: String,
    kind_filter: Option<String>,
) -> Result<()> {
    let absolute = make_absolute(&vault_path)?;
    let id = NoteId::parse(&note_id)?;
    let vault = Vault::open(&absolute)?;
    let note = core_get_note(&vault, &id)?;

    let want_out = dir == "out" || dir == "both";
    let want_in = dir == "in" || dir == "both";

    let kind = match kind_filter {
        Some(k) => Some(LinkKind::new(&k).map_err(|e| invalid_argument("invalid kind", e))?),
        None => None,
    };

    println!("{}  ({})", note.title, note.id);
    if want_out {
        let outgoing = core_links::links_out_for_note(&vault, note.id.as_str())?;
        let filtered: Vec<_> = outgoing
            .into_iter()
            .filter(|l| match &kind {
                Some(k) => l.link_kind == *k,
                None => true,
            })
            .collect();
        print_link_tree("outgoing", &filtered, &vault)?;
    }
    if want_in {
        let incoming = core_links::links_in_for_note(&vault, note.id.as_str(), kind.as_ref())?;
        print_link_tree("incoming", &incoming, &vault)?;
    }
    Ok(())
}

fn print_link_tree(
    label: &str,
    links: &[core_links::Link],
    vault: &Vault,
) -> Result<()> {
    println!("├─ {label} ({})", links.len());
    if links.is_empty() {
        println!("│   (none)");
        return Ok(());
    }
    // Group by kind. Built-ins first, then user-defined alphabetically.
    use std::collections::BTreeMap;
    let mut by_kind: BTreeMap<String, Vec<&core_links::Link>> = BTreeMap::new();
    for l in links {
        by_kind
            .entry(l.link_kind.as_str().to_string())
            .or_default()
            .push(l);
    }
    let order = ops::notes::ordered_kinds(by_kind.keys().cloned().collect());
    for k in order {
        let items = by_kind.get(&k).cloned().unwrap_or_default();
        println!("│   {k} ({})", items.len());
        for l in items {
            let other_id = if label == "outgoing" {
                l.to_note_id.clone()
            } else {
                Some(l.from_note_id.clone())
            };
            let other_title = match other_id.as_deref() {
                Some(oid) => match NoteId::parse(oid) {
                    Ok(parsed) => core_get_note(vault, &parsed)
                        .map(|n| n.title)
                        .unwrap_or_else(|_| oid.to_string()),
                    Err(_) => oid.to_string(),
                },
                None => format!("(ghost: {})", l.link_text),
            };
            let extra = match l.label.as_deref() {
                Some(lab) => format!(" \"{lab}\""),
                None => String::new(),
            };
            println!("│       · {other_title}{extra}");
        }
    }
    Ok(())
}

async fn cmd_add_link(
    vault_path: PathBuf,
    from: String,
    to: String,
    kind: String,
    label: Option<String>,
    with_embeddings: bool,
) -> Result<()> {
    let absolute = make_absolute(&vault_path)?;
    let input = ops::links::AddLinkInput {
        from,
        to,
        kind,
        label,
    };
    input.validate()?;

    let mut vault = Vault::open(&absolute).context("open vault")?;
    let embedder = if with_embeddings {
        Some(build_default_embedder(&absolute))
    } else {
        None
    };
    let out = ops::links::add_link(&mut vault, input, &SystemClock, embedder.as_deref())?;
    println!("{}", serde_json::to_string(&out)?);
    Ok(())
}

async fn cmd_update_link(
    vault_path: PathBuf,
    link_id: String,
    kind: Option<String>,
    label: Option<String>,
    clear_label: bool,
    _with_embeddings: bool,
) -> Result<()> {
    let absolute = make_absolute(&vault_path)?;
    let mut vault = Vault::open(&absolute).context("open vault")?;
    let input = ops::links::UpdateLinkInput {
        link_id,
        kind,
        label,
        clear_label,
    };
    let out = ops::links::update_link(&mut vault, input, &SystemClock, None)?;
    println!("{}", serde_json::to_string(&out)?);
    Ok(())
}

fn cmd_canvas(action: CanvasAction) -> Result<()> {
    let clock = SystemClock;
    match action {
        CanvasAction::New { vault, title } => {
            let mut vault = open_vault(vault)?;
            let input = ops::canvas::NewInput { title };
            print_json(&ops::canvas::new(&mut vault, input, &clock, None)?)
        }
        CanvasAction::Ls { vault } => {
            let mut vault = open_vault(vault)?;
            let input = ops::canvas::LsInput;
            print_json(&ops::canvas::ls(&mut vault, input, &clock, None)?)
        }
        CanvasAction::Get { vault, canvas_id } => {
            let mut vault = open_vault(vault)?;
            let input = ops::canvas::GetInput { canvas_id };
            print_json(&ops::canvas::get(&mut vault, input, &clock, None)?)
        }
        CanvasAction::Rename {
            vault,
            canvas_id,
            title,
            expected_version,
        } => {
            let mut vault = open_vault(vault)?;
            let input = ops::canvas::RenameInput {
                canvas_id,
                title,
                expected_version,
            };
            print_json(&ops::canvas::rename(&mut vault, input, &clock, None)?)
        }
        CanvasAction::Rm {
            vault,
            canvas_id,
            expected_version,
        } => {
            let mut vault = open_vault(vault)?;
            let input = ops::canvas::RmInput {
                canvas_id,
                expected_version,
            };
            print_json(&ops::canvas::rm(&mut vault, input, &clock, None)?)
        }
        CanvasAction::Add {
            vault,
            canvas_id,
            note_id,
            x,
            y,
        } => {
            let mut vault = open_vault(vault)?;
            let input = ops::canvas::AddInput {
                canvas_id,
                note_id,
                x,
                y,
            };
            print_json(&ops::canvas::add(&mut vault, input, &clock, None)?)
        }
        CanvasAction::Remove {
            vault,
            canvas_id,
            note_id,
        } => {
            let mut vault = open_vault(vault)?;
            let input = ops::canvas::RemoveInput { canvas_id, note_id };
            print_json(&ops::canvas::remove(&mut vault, input, &clock, None)?)
        }
        CanvasAction::Move {
            vault,
            canvas_id,
            note_id,
            x,
            y,
            z,
        } => {
            let mut vault = open_vault(vault)?;
            let input = ops::canvas::MoveInput {
                canvas_id,
                note_id,
                x,
                y,
                z,
            };
            print_json(&ops::canvas::move_node(&mut vault, input, &clock, None)?)
        }
    }
}

fn open_vault(vault_path: PathBuf) -> Result<Vault> {
    let absolute = make_absolute(&vault_path)?;
    Vault::open(&absolute).context("open vault")
}

/// One JSON line on stdout.
fn print_json<T: serde::Serialize>(out: &T) -> Result<()> {
    println!("{}", serde_json::to_string(out)?);
    Ok(())
}

async fn cmd_serve(vault_path: PathBuf, with_embeddings: bool, log_level: String) -> Result<()> {
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

    let service = memex.serve(stdio()).await.context("start MCP service")?;
    service
        .waiting()
        .await
        .context("MCP service exited unexpectedly")?;
    Ok(())
}

/// A core validation failure on a CLI argument (`--kind`), reported as
/// `invalid_argument` rather than the core error's code.
fn invalid_argument(what: &str, e: memex_core::MemexError) -> anyhow::Error {
    InvalidArgument(format!("{what}: {e}")).into()
}

fn make_absolute(p: &PathBuf) -> Result<PathBuf> {
    if p.is_absolute() {
        Ok(p.clone())
    } else {
        Ok(std::env::current_dir()?.join(p))
    }
}
