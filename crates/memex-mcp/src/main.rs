use std::path::PathBuf;
use std::process::ExitCode;
use std::sync::Arc;

use anyhow::{Context, Result};
use clap::{Parser, Subcommand};
use memex_core::canvas;
use memex_core::indexer;
use memex_core::links::{self as core_links, LinkKind, LinkSource, PendingLink};
use memex_core::notes::{
    create_note, get_note as core_get_note, list_notes, update_note_with_options, CreateNote,
    NoteId, RenameOptions, UpdateNote,
};
use memex_core::tags;
use memex_core::{excerpts, review};
use memex_core::{CanvasId, Vault};
use rmcp::transport::stdio;
use rmcp::ServiceExt;
use rusqlite::params;
use tracing_subscriber::EnvFilter;

use memex_mcp::cli::{self, InvalidArgument, Role};
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
    // C2.1: a daily note may start empty; its title defaults to today (local).
    let daily = role == Some(Role::Daily);
    if buf.trim().is_empty() && !daily {
        let msg = "stdin was empty — nothing to add".to_string();
        return Err(InvalidArgument(msg).into());
    }

    let mut vault = Vault::open(&absolute).context("open vault")?;
    let frontmatter = role.map(|r| serde_json::json!({ "role": r.as_str() }));
    let (note, first_line) = if daily {
        let clock = memex_core::SystemClock;
        let date = memex_core::daily::resolve_date(title.as_deref(), &clock)?;
        let content_md = if buf.trim().is_empty() {
            String::new()
        } else {
            buf
        };
        let input = CreateNote {
            title: Some(date.to_string()),
            content_md,
            frontmatter,
        };
        let outcome = memex_core::notes::create_or_adopt_note(
            &mut vault,
            input,
            memex_core::Caller::Person,
            &clock,
        )?;
        let first_line = if outcome.adopted {
            "Adopted note"
        } else {
            "Created note"
        };
        (outcome.note, first_line)
    } else {
        let input = CreateNote {
            title,
            content_md: buf,
            frontmatter,
        };
        (create_note(&mut vault, input)?, "Created note")
    };
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
        &note.content_md,
        embedder.as_deref(),
    )?;

    println!("{first_line}");
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

    let id = NoteId::parse(&note_id)?;
    let mut vault = Vault::open(&absolute).context("open vault")?;
    let updated = update_note_with_options(
        &mut vault,
        &id,
        expected_version,
        UpdateNote {
            title,
            content_md: Some(buf),
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
        &updated.content_md,
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
    let id = NoteId::parse(&note_id)?;
    let vault = Vault::open(&absolute)?;
    let note = core_get_note(&vault, &id)?;
    let tag_list = tags::tags_for_note(&vault, note.id.as_str()).unwrap_or_default();
    // Review and transclusion fields join the top level (D7).
    let mut fields = review::note_review_fields(&vault, &note)?;
    fields.extend(excerpts::note_transclusion_fields(&vault, &note)?);
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
    if let Some(obj) = payload.as_object_mut() {
        obj.extend(fields);
    }
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
    let from_id = NoteId::parse(&from)?;
    let to_id = NoteId::parse(&to)?;
    let kind_obj = LinkKind::new(&kind).map_err(|e| invalid_argument("invalid --kind", e))?;

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
            content_md: Some(new_md),
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
        &updated.content_md,
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
    let new_kind = match kind {
        Some(k) => Some(LinkKind::new(&k).map_err(|e| invalid_argument("invalid --kind", e))?),
        None => None,
    };
    let new_label: Option<Option<String>> = if clear_label {
        Some(None)
    } else {
        label.map(Some)
    };
    let link = core_links::update_link(
        &mut vault,
        &link_id,
        core_links::UpdateLink {
            new_kind,
            new_label,
        },
    )?;
    println!(
        "{}",
        serde_json::to_string(&serde_json::json!({
            "vault_id": vault.vault_id(),
            "link_id": link.id,
            "from_note_id": link.from_note_id,
            "to_note_id": link.to_note_id,
            "kind": link.link_kind.as_str(),
            "label": link.label,
            "source": link.source.as_str(),
            "position": link.position,
        }))?
    );
    Ok(())
}

fn cmd_canvas(action: CanvasAction) -> Result<()> {
    match action {
        CanvasAction::New { vault, title } => cmd_canvas_new(vault, title),
        CanvasAction::Ls { vault } => cmd_canvas_ls(vault),
        CanvasAction::Get { vault, canvas_id } => cmd_canvas_get(vault, canvas_id),
        CanvasAction::Rename {
            vault,
            canvas_id,
            title,
            expected_version,
        } => cmd_canvas_rename(vault, canvas_id, title, expected_version),
        CanvasAction::Rm {
            vault,
            canvas_id,
            expected_version,
        } => cmd_canvas_rm(vault, canvas_id, expected_version),
        CanvasAction::Add {
            vault,
            canvas_id,
            note_id,
            x,
            y,
        } => cmd_canvas_add(vault, canvas_id, note_id, x, y),
        CanvasAction::Remove {
            vault,
            canvas_id,
            note_id,
        } => cmd_canvas_remove(vault, canvas_id, note_id),
        CanvasAction::Move {
            vault,
            canvas_id,
            note_id,
            x,
            y,
            z,
        } => cmd_canvas_move(vault, canvas_id, note_id, x, y, z),
    }
}

fn open_vault(vault_path: PathBuf) -> Result<(PathBuf, Vault)> {
    let absolute = make_absolute(&vault_path)?;
    let vault = Vault::open(&absolute).context("open vault")?;
    Ok((absolute, vault))
}

fn parse_canvas_id(s: &str) -> Result<CanvasId> {
    Ok(CanvasId::parse(s)?)
}

fn cmd_canvas_new(vault_path: PathBuf, title: String) -> Result<()> {
    let (_abs, mut vault) = open_vault(vault_path)?;
    let c = canvas::create_canvas(&mut vault, title)?;
    println!(
        "{}",
        serde_json::to_string(&serde_json::json!({
            "vault_id": vault.vault_id(),
            "canvas_id": c.id.to_string(),
            "title": c.title,
            "version": c.version,
            "created_at": c.created_at,
            "updated_at": c.updated_at,
        }))?
    );
    Ok(())
}

fn cmd_canvas_ls(vault_path: PathBuf) -> Result<()> {
    let (_abs, vault) = open_vault(vault_path)?;
    let summaries = canvas::list_canvases(&vault)?;
    let arr: Vec<serde_json::Value> = summaries
        .into_iter()
        .map(|s| {
            serde_json::json!({
                "canvas_id": s.id.to_string(),
                "title": s.title,
                "created_at": s.created_at,
                "updated_at": s.updated_at,
                "version": s.version,
                "node_count": s.node_count,
            })
        })
        .collect();
    println!(
        "{}",
        serde_json::to_string(&serde_json::json!({
            "vault_id": vault.vault_id(),
            "canvases": arr,
        }))?
    );
    Ok(())
}

fn cmd_canvas_get(vault_path: PathBuf, canvas_id: String) -> Result<()> {
    let (_abs, vault) = open_vault(vault_path)?;
    let cid = parse_canvas_id(&canvas_id)?;
    let d = canvas::get_canvas(&vault, &cid)?;
    let nodes: Vec<serde_json::Value> = d
        .nodes
        .into_iter()
        .map(|n| {
            serde_json::json!({
                "note_id": n.note_id,
                "note_title": n.note_title,
                "x": n.x,
                "y": n.y,
                "z_order": n.z_order,
                "placed_at": n.placed_at,
            })
        })
        .collect();
    let edges: Vec<serde_json::Value> = d
        .edges
        .into_iter()
        .map(|e| {
            serde_json::json!({
                "link_id": e.link_id,
                "from_note_id": e.from_note_id,
                "to_note_id": e.to_note_id,
                "link_text": e.link_text,
                "kind": e.link_kind.as_str(),
                "label": e.label,
                "source": e.source.as_str(),
                "position": e.position,
            })
        })
        .collect();
    println!(
        "{}",
        serde_json::to_string(&serde_json::json!({
            "vault_id": vault.vault_id(),
            "canvas_id": d.canvas.id.to_string(),
            "title": d.canvas.title,
            "created_at": d.canvas.created_at,
            "updated_at": d.canvas.updated_at,
            "version": d.canvas.version,
            "nodes": nodes,
            "edges": edges,
        }))?
    );
    Ok(())
}

fn cmd_canvas_rename(
    vault_path: PathBuf,
    canvas_id: String,
    title: String,
    expected_version: i64,
) -> Result<()> {
    let (_abs, mut vault) = open_vault(vault_path)?;
    let cid = parse_canvas_id(&canvas_id)?;
    let c = canvas::rename_canvas(&mut vault, &cid, title, expected_version)?;
    println!(
        "{}",
        serde_json::to_string(&serde_json::json!({
            "vault_id": vault.vault_id(),
            "canvas_id": c.id.to_string(),
            "title": c.title,
            "version": c.version,
            "updated_at": c.updated_at,
        }))?
    );
    Ok(())
}

fn cmd_canvas_rm(vault_path: PathBuf, canvas_id: String, expected_version: i64) -> Result<()> {
    let (_abs, mut vault) = open_vault(vault_path)?;
    let cid = parse_canvas_id(&canvas_id)?;
    canvas::delete_canvas(&mut vault, &cid, expected_version)?;
    println!(
        "{}",
        serde_json::to_string(&serde_json::json!({
            "vault_id": vault.vault_id(),
            "canvas_id": canvas_id,
        }))?
    );
    Ok(())
}

fn cmd_canvas_add(
    vault_path: PathBuf,
    canvas_id: String,
    note_id: String,
    x: f64,
    y: f64,
) -> Result<()> {
    let (_abs, mut vault) = open_vault(vault_path)?;
    let cid = parse_canvas_id(&canvas_id)?;
    NoteId::parse(&note_id)?;
    let node = canvas::add_to_canvas(&mut vault, &cid, &note_id, x, y)?;
    println!(
        "{}",
        serde_json::to_string(&serde_json::json!({
            "vault_id": vault.vault_id(),
            "canvas_id": node.canvas_id.to_string(),
            "note_id": node.note_id,
            "note_title": node.note_title,
            "x": node.x,
            "y": node.y,
            "z_order": node.z_order,
            "placed_at": node.placed_at,
        }))?
    );
    Ok(())
}

fn cmd_canvas_remove(
    vault_path: PathBuf,
    canvas_id: String,
    note_id: String,
) -> Result<()> {
    let (_abs, mut vault) = open_vault(vault_path)?;
    let cid = parse_canvas_id(&canvas_id)?;
    canvas::remove_from_canvas(&mut vault, &cid, &note_id)?;
    println!(
        "{}",
        serde_json::to_string(&serde_json::json!({
            "vault_id": vault.vault_id(),
            "canvas_id": canvas_id,
            "note_id": note_id,
        }))?
    );
    Ok(())
}

fn cmd_canvas_move(
    vault_path: PathBuf,
    canvas_id: String,
    note_id: String,
    x: f64,
    y: f64,
    z: Option<i64>,
) -> Result<()> {
    let (_abs, mut vault) = open_vault(vault_path)?;
    let cid = parse_canvas_id(&canvas_id)?;
    let node = canvas::move_node(&mut vault, &cid, &note_id, x, y, z)?;
    println!(
        "{}",
        serde_json::to_string(&serde_json::json!({
            "vault_id": vault.vault_id(),
            "canvas_id": node.canvas_id.to_string(),
            "note_id": node.note_id,
            "note_title": node.note_title,
            "x": node.x,
            "y": node.y,
            "z_order": node.z_order,
        }))?
    );
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
