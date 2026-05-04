use std::path::PathBuf;
use std::sync::Arc;

use anyhow::{Context, Result};
use clap::{Parser, Subcommand};
use memex_core::indexer;
use memex_core::links::{self as core_links, LinkKind, LinkSource, PendingLink};
use memex_core::notes::{
    create_note, get_note as core_get_note, list_notes, update_note_with_options, CreateNote,
    NoteId, RenameOptions, UpdateNote,
};
use memex_core::tags;
use memex_core::Vault;
use rmcp::transport::stdio;
use rmcp::ServiceExt;
use rusqlite::params;
use tracing_subscriber::EnvFilter;

use memex_mcp::md_links;
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

    let id = NoteId::parse(&note_id).map_err(|e| anyhow::anyhow!("invalid note_id: {e}"))?;
    let mut vault = Vault::open(&absolute).context("open vault")?;
    let updated = update_note_with_options(
        &mut vault,
        &id,
        expected_version,
        UpdateNote {
            title,
            content_md: Some(buf.clone()),
            frontmatter: None,
        },
        RenameOptions {
            rename_links: !no_rename_links,
        },
    )?;

    let embedder = if with_embeddings {
        Some(build_default_embedder(&absolute))
    } else {
        None
    };
    indexer::reindex_note(
        vault.connection_mut(),
        updated.id.as_str(),
        &buf,
        embedder.as_deref(),
    )?;

    println!(
        "{}",
        serde_json::to_string(&UpdateOutput {
            note_id: updated.id.to_string(),
            version: updated.version,
            updated_at: updated.updated_at,
        })?
    );
    Ok(())
}

fn cmd_get(vault_path: PathBuf, note_id: String, include_links: bool) -> Result<()> {
    let absolute = make_absolute(&vault_path)?;
    let id = NoteId::parse(&note_id).map_err(|e| anyhow::anyhow!("invalid note_id: {e}"))?;
    let vault = Vault::open(&absolute)?;
    let note = core_get_note(&vault, &id)?;
    let tag_list = tags::tags_for_note(&vault, note.id.as_str()).unwrap_or_default();
    let mut payload = serde_json::json!({
        "note_id": note.id.to_string(),
        "title": note.title,
        "content_md": note.content_md,
        "frontmatter": note.frontmatter,
        "version": note.version,
        "created_at": note.created_at,
        "updated_at": note.updated_at,
        "tags": tag_list,
    });
    if include_links {
        let outgoing = core_links::links_out_for_note(&vault, note.id.as_str())
            .unwrap_or_default();
        let incoming = core_links::links_in_for_note(&vault, note.id.as_str(), None)
            .unwrap_or_default();
        payload["links"] = serde_json::json!(group_links_by_kind(&outgoing));
        payload["backlinks"] = serde_json::json!(group_links_by_kind(&incoming));
    }
    println!("{}", serde_json::to_string(&payload)?);
    Ok(())
}

#[derive(serde::Serialize)]
struct UpdateOutput {
    note_id: String,
    version: i64,
    updated_at: i64,
}

fn cmd_links(
    vault_path: PathBuf,
    note_id: String,
    dir: String,
    kind_filter: Option<String>,
) -> Result<()> {
    let absolute = make_absolute(&vault_path)?;
    let id = NoteId::parse(&note_id).map_err(|e| anyhow::anyhow!("invalid note_id: {e}"))?;
    let vault = Vault::open(&absolute)?;
    let note = core_get_note(&vault, &id)?;

    let want_out = dir == "out" || dir == "both";
    let want_in = dir == "in" || dir == "both";

    let kind = match kind_filter {
        Some(k) => Some(LinkKind::new(&k).map_err(|e| anyhow::anyhow!("invalid kind: {e}"))?),
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
    let order = ordered_kinds(by_kind.keys().cloned().collect());
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

fn ordered_kinds(kinds: Vec<String>) -> Vec<String> {
    const BUILT_IN: [&str; 4] = ["references", "extends", "contradicts", "example-of"];
    let mut out: Vec<String> = Vec::new();
    let mut user_defined: Vec<String> = Vec::new();
    for k in &kinds {
        if BUILT_IN.contains(&k.as_str()) {
            // skip; we'll add in canonical order
        } else {
            user_defined.push(k.clone());
        }
    }
    user_defined.sort();
    for b in BUILT_IN {
        if kinds.iter().any(|k| k == b) {
            out.push(b.to_string());
        }
    }
    out.extend(user_defined);
    out
}

fn group_links_by_kind(links: &[core_links::Link]) -> serde_json::Map<String, serde_json::Value> {
    use std::collections::BTreeMap;
    let mut by_kind: BTreeMap<String, Vec<serde_json::Value>> = BTreeMap::new();
    for l in links {
        by_kind
            .entry(l.link_kind.as_str().to_string())
            .or_default()
            .push(serde_json::json!({
                "link_id": l.id,
                "from_note_id": l.from_note_id,
                "to_note_id": l.to_note_id,
                "link_text": l.link_text,
                "label": l.label,
                "source": l.source.as_str(),
                "position": l.position,
            }));
    }
    let mut out = serde_json::Map::new();
    let order = ordered_kinds(by_kind.keys().cloned().collect());
    for k in order {
        if let Some(v) = by_kind.remove(&k) {
            out.insert(k, serde_json::Value::Array(v));
        }
    }
    out
}

#[derive(serde::Serialize)]
struct AddLinkOutput {
    vault_id: String,
    link_id: Option<String>,
    from: String,
    to: String,
    kind: String,
    source: String,
    was_existing: bool,
    note_version: i64,
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
    let from_id = NoteId::parse(&from).map_err(|e| anyhow::anyhow!("invalid --from: {e}"))?;
    let to_id = NoteId::parse(&to).map_err(|e| anyhow::anyhow!("invalid --to: {e}"))?;
    let kind_obj = LinkKind::new(&kind)
        .map_err(|e| anyhow::anyhow!("invalid --kind: {e}"))?;

    let mut vault = Vault::open(&absolute).context("open vault")?;
    let source = core_get_note(&vault, &from_id)?;
    let target = core_get_note(&vault, &to_id)?;
    let vault_id = vault.vault_id().to_string();

    // Idempotency: if a link of this kind already exists from source to target,
    // return early.
    let existing = vault.connection_ref().query_row(
        "SELECT id FROM links WHERE from_note_id = ? AND to_note_id = ? AND link_kind = ? LIMIT 1",
        params![source.id.as_str(), target.id.as_str(), kind_obj.as_str()],
        |r| r.get::<_, String>(0),
    );
    if let Ok(link_id) = existing {
        let chosen_source = if kind_obj.as_str() == LinkKind::REFERENCES {
            LinkSource::AutoAdded
        } else {
            LinkSource::Frontmatter
        };
        let payload = AddLinkOutput {
            vault_id,
            link_id: Some(link_id),
            from: source.id.to_string(),
            to: target.id.to_string(),
            kind: kind_obj.as_str().to_string(),
            source: chosen_source.as_str().to_string(),
            was_existing: true,
            note_version: source.version,
        };
        println!("{}", serde_json::to_string(&payload)?);
        return Ok(());
    }

    // Insert into the source note's markdown.
    let new_md = md_links::insert_link_into_markdown(
        &source.content_md,
        &target.title,
        kind_obj.as_str(),
        label.as_deref(),
    );
    let chosen_source = if kind_obj.as_str() == LinkKind::REFERENCES {
        LinkSource::AutoAdded
    } else {
        LinkSource::Frontmatter
    };

    // Apply the update without firing the title-rename pass.
    let updated = update_note_with_options(
        &mut vault,
        &source.id,
        source.version,
        UpdateNote {
            content_md: Some(new_md.clone()),
            ..Default::default()
        },
        RenameOptions { rename_links: false },
    )?;

    let embedder = if with_embeddings {
        Some(build_default_embedder(&absolute))
    } else {
        None
    };
    indexer::reindex_note(
        vault.connection_mut(),
        updated.id.as_str(),
        &new_md,
        embedder.as_deref(),
    )?;

    // Find the new link's id.
    let link_id: Option<String> = vault.connection_ref().query_row(
        "SELECT id FROM links
            WHERE from_note_id = ? AND to_note_id = ? AND link_kind = ?
            ORDER BY position DESC LIMIT 1",
        params![source.id.as_str(), target.id.as_str(), kind_obj.as_str()],
        |r| r.get(0),
    ).ok();

    // Feed `label` through to the row if provided. The extractor parses
    // `[[Title|alias]]` into `label` automatically.
    let _ = label;
    // PendingLink import keeps the type wired in case the public API needs
    // direct insertion later.
    let _ = std::marker::PhantomData::<PendingLink>;

    let payload = AddLinkOutput {
        vault_id,
        link_id,
        from: source.id.to_string(),
        to: target.id.to_string(),
        kind: kind_obj.as_str().to_string(),
        source: chosen_source.as_str().to_string(),
        was_existing: false,
        note_version: updated.version,
    };
    println!("{}", serde_json::to_string(&payload)?);
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

fn make_absolute(p: &PathBuf) -> Result<PathBuf> {
    if p.is_absolute() {
        Ok(p.clone())
    } else {
        Ok(std::env::current_dir()?.join(p))
    }
}
