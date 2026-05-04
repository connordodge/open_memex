//! MCP tool definitions. Each tool returns a JSON-encoded string so callers
//! can parse a stable shape without depending on rmcp's content typing.

use std::sync::Arc;

use memex_core::graph;
use memex_core::indexer;
use memex_core::links::{self as core_links, LinkKind, LinkSource};
use memex_core::notes::{
    self, update_note_with_options, CreateNote, NoteId, RenameOptions, UpdateNote,
};
use memex_core::search::{self, SearchFilters, SearchMode, SearchOptions};
use memex_core::tags;
use rmcp::handler::server::router::tool::ToolRouter;
use rmcp::handler::server::wrapper::Parameters;
use rmcp::{tool, tool_handler, tool_router, ServerHandler};
use rusqlite::params;
use schemars::JsonSchema;
use serde::{Deserialize, Serialize};

use crate::md_links;
use crate::state::AppState;

#[derive(Clone)]
pub struct Memex {
    pub state: Arc<AppState>,
    tool_router: ToolRouter<Self>,
}

impl Memex {
    pub fn new(state: Arc<AppState>) -> Self {
        Self {
            state,
            tool_router: Self::tool_router(),
        }
    }
}

#[derive(Debug, Deserialize, JsonSchema)]
pub struct SearchParams {
    /// The search query. Plain keywords or natural language.
    pub query: String,
    /// Maximum number of results to return. Default 10.
    #[serde(default)]
    pub k: Option<usize>,
    /// Search mode: "hybrid" (default), "fts", or "vector".
    #[serde(default)]
    pub mode: Option<String>,
    /// Optional list of tags; results restricted to notes that have all of them.
    #[serde(default)]
    pub tags: Option<Vec<String>>,
    /// Optional note id to scope the search to a single note.
    #[serde(default)]
    pub note_id: Option<String>,
}

fn parse_mode(s: Option<String>) -> SearchMode {
    match s.as_deref().map(|x| x.to_ascii_lowercase()) {
        Some(ref s) if s == "fts" => SearchMode::Fts,
        Some(ref s) if s == "vector" => SearchMode::Vector,
        _ => SearchMode::Hybrid,
    }
}

#[derive(Debug, Serialize)]
pub struct SearchResultEnvelope {
    pub vault_id: String,
    pub query: String,
    pub mode: SearchMode,
    pub results: Vec<search::SearchHit>,
    pub truncated: bool,
}

#[derive(Debug, Deserialize, JsonSchema)]
pub struct GetNoteParams {
    /// The note id (ULID).
    pub note_id: String,
    /// If true, include outgoing `links` and incoming `backlinks` in the
    /// response, both grouped by kind (built-ins first, user-defined kinds
    /// alphabetically).
    #[serde(default)]
    pub include_backlinks: Option<bool>,
}

#[derive(Debug, Serialize)]
pub struct GetNoteEnvelope {
    pub vault_id: String,
    pub note_id: String,
    pub title: String,
    pub content_md: String,
    pub frontmatter: serde_json::Value,
    pub version: i64,
    pub created_at: i64,
    pub updated_at: i64,
    pub tags: Vec<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub links: Option<serde_json::Map<String, serde_json::Value>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub backlinks: Option<serde_json::Map<String, serde_json::Value>>,
}

#[derive(Debug, Deserialize, JsonSchema)]
pub struct NeighborsParams {
    /// The note id (ULID) to start the traversal from.
    pub note_id: String,
    /// BFS depth, clamped server-side to [1, 3]. Default 1.
    #[serde(default)]
    pub depth: Option<i64>,
    /// Optional kind filter (e.g. `extends`, `inspired-by`). Restricts which
    /// edges are followed.
    #[serde(default)]
    pub kind: Option<String>,
}

#[derive(Debug, Serialize)]
pub struct NeighborsEnvelope {
    pub vault_id: String,
    pub root_note_id: String,
    pub depth: i64,
    pub results: Vec<graph::NeighborHit>,
}

#[derive(Debug, Deserialize, JsonSchema)]
pub struct AddLinkParams {
    /// Source note id. Must exist.
    pub from_id: String,
    /// Target note id. Must exist.
    pub to_id: String,
    /// Kind. Built-in (`references`, `extends`, `contradicts`, `example-of`)
    /// or any normalized kebab-case kind. Default: `references`.
    #[serde(default)]
    pub kind: Option<String>,
    /// Optional human-readable display alias. Rendered as the `|alias`
    /// segment of the wikilink.
    #[serde(default)]
    pub label: Option<String>,
}

#[derive(Debug, Serialize)]
pub struct AddLinkEnvelope {
    pub vault_id: String,
    pub link_id: Option<String>,
    pub from_id: String,
    pub to_id: String,
    pub kind: String,
    pub source: String,
    pub was_existing: bool,
    pub note_version: i64,
}

#[derive(Debug, Deserialize, JsonSchema)]
pub struct CreateNoteParams {
    /// Markdown content of the note.
    pub content_md: String,
    /// Optional title. If omitted, derived from the first line of content.
    #[serde(default)]
    pub title: Option<String>,
    /// Optional tags to attach.
    #[serde(default)]
    pub tags: Option<Vec<String>>,
    /// Identifier for the agent creating this note. Stored in frontmatter.
    #[serde(default)]
    pub agent_id: Option<String>,
}

#[derive(Debug, Serialize)]
pub struct CreateNoteEnvelope {
    pub vault_id: String,
    pub note_id: String,
    pub version: i64,
}

#[tool_router(router = tool_router)]
impl Memex {
    /// Hybrid search (FTS + vector) over the user's notes. Returns ranked chunks.
    #[tool(description = "Search the user's notes by keyword or meaning. \
        Returns ranked chunks with snippets. Each result has a stable note_id \
        and chunk_id so you can call get_note for full context.")]
    pub async fn search(&self, params: Parameters<SearchParams>) -> String {
        let SearchParams { query, k, mode, tags, note_id } = params.0;
        let k = k.unwrap_or(10).clamp(1, 50);
        let mode = parse_mode(mode);
        let filters = SearchFilters {
            tags_all: tags.unwrap_or_default(),
            note_id,
        };

        let vault = self.state.vault.lock().await;
        let opts = SearchOptions {
            query: &query,
            k,
            mode,
            filters,
            embedder: self.state.embedder_ref(),
        };
        match search::search(vault.connection_ref(), opts) {
            Ok(res) => serde_json::to_string(&SearchResultEnvelope {
                vault_id: vault.vault_id().to_string(),
                query,
                mode,
                results: res.hits,
                truncated: res.truncated,
            })
            .unwrap_or_else(|e| err_payload("search.serialize", &e.to_string())),
            Err(e) => err_payload("search", &e.to_string()),
        }
    }

    /// Fetch the full content of a note by id.
    #[tool(description = "Retrieve a single note by its id. \
        Use this after `search` to read the full content of a relevant note. \
        Set `include_backlinks: true` to also receive `links` (outgoing) and \
        `backlinks` (incoming) maps grouped by kind.")]
    pub async fn get_note(&self, params: Parameters<GetNoteParams>) -> String {
        let GetNoteParams {
            note_id,
            include_backlinks,
        } = params.0;
        let id = match NoteId::parse(&note_id) {
            Ok(i) => i,
            Err(e) => return err_payload("get_note.invalid_id", &e.to_string()),
        };
        let vault = self.state.vault.lock().await;
        match notes::get_note(&vault, &id) {
            Ok(n) => {
                let tags = tags::tags_for_note(&vault, n.id.as_str()).unwrap_or_default();
                let (links_map, backlinks_map) = if include_backlinks.unwrap_or(false) {
                    let outgoing = core_links::links_out_for_note(&vault, n.id.as_str())
                        .unwrap_or_default();
                    let incoming = core_links::links_in_for_note(&vault, n.id.as_str(), None)
                        .unwrap_or_default();
                    (
                        Some(group_links_by_kind(&outgoing)),
                        Some(group_links_by_kind(&incoming)),
                    )
                } else {
                    (None, None)
                };
                serde_json::to_string(&GetNoteEnvelope {
                    vault_id: vault.vault_id().to_string(),
                    note_id: n.id.to_string(),
                    title: n.title,
                    content_md: n.content_md,
                    frontmatter: n.frontmatter,
                    version: n.version,
                    created_at: n.created_at,
                    updated_at: n.updated_at,
                    tags,
                    links: links_map,
                    backlinks: backlinks_map,
                })
                .unwrap_or_else(|e| err_payload("get_note.serialize", &e.to_string()))
            }
            Err(e) => err_payload("get_note", &e.to_string()),
        }
    }

    /// BFS over the link graph from a starting note. Self-edges are excluded.
    #[tool(description = "Walk the link graph adjacent to a note. Returns \
        notes within `depth` hops with their edge metadata (kind + label). \
        Treats the graph as undirected — an edge counts whether it points in \
        or out. Use this when you want \"what's connected to this idea?\" \
        without re-running search. Depth is clamped server-side to [1, 3]. \
        Optional `kind` filter restricts which edges are followed.")]
    pub async fn neighbors(&self, params: Parameters<NeighborsParams>) -> String {
        let NeighborsParams {
            note_id,
            depth,
            kind,
        } = params.0;
        if NoteId::parse(&note_id).is_err() {
            return err_payload("neighbors.invalid_id", &note_id);
        }
        // Validate kind early at the server boundary.
        let kind_normalized = match kind.as_deref() {
            Some(k) => match LinkKind::new(k) {
                Ok(lk) => Some(lk.as_str().to_string()),
                Err(e) => return err_payload("neighbors.invalid_kind", &e.to_string()),
            },
            None => None,
        };
        let depth = depth.unwrap_or(1).clamp(1, graph::MAX_DEPTH);

        let vault = self.state.vault.lock().await;
        match graph::neighbors(
            vault.connection_ref(),
            &note_id,
            depth,
            kind_normalized.as_deref(),
        ) {
            Ok(results) => serde_json::to_string(&NeighborsEnvelope {
                vault_id: vault.vault_id().to_string(),
                root_note_id: note_id,
                depth,
                results,
            })
            .unwrap_or_else(|e| err_payload("neighbors.serialize", &e.to_string())),
            Err(e) => err_payload("neighbors", &e.to_string()),
        }
    }

    /// Add a wikilink from one note to another. Inserts into the source
    /// note's markdown per the destination rule.
    #[tool(description = "Add a wikilink from one note to another. \
        `kind=references` (default) appends `[[Target]]` to a `## Auto-added \
        links` section at the bottom of the source note. Any other kind \
        (built-in or user-defined kebab-case) writes into YAML frontmatter \
        under that kind key. Idempotent: if the same link already exists, \
        returns the existing link_id with `was_existing: true`.")]
    pub async fn add_link(&self, params: Parameters<AddLinkParams>) -> String {
        let AddLinkParams {
            from_id,
            to_id,
            kind,
            label,
        } = params.0;
        let from = match NoteId::parse(&from_id) {
            Ok(i) => i,
            Err(e) => return err_payload("add_link.invalid_from", &e.to_string()),
        };
        let to = match NoteId::parse(&to_id) {
            Ok(i) => i,
            Err(e) => return err_payload("add_link.invalid_to", &e.to_string()),
        };
        let kind_obj = match kind.as_deref() {
            Some(k) => match LinkKind::new(k) {
                Ok(lk) => lk,
                Err(e) => return err_payload("add_link.invalid_kind", &e.to_string()),
            },
            None => LinkKind::references(),
        };

        let mut vault = self.state.vault.lock().await;
        let vault_id = vault.vault_id().to_string();

        let source = match notes::get_note(&vault, &from) {
            Ok(n) => n,
            Err(e) => return err_payload("add_link.from_not_found", &e.to_string()),
        };
        let target = match notes::get_note(&vault, &to) {
            Ok(n) => n,
            Err(e) => return err_payload("add_link.to_not_found", &e.to_string()),
        };

        // Idempotency check.
        let existing: Option<String> = vault
            .connection_ref()
            .query_row(
                "SELECT id FROM links WHERE from_note_id = ? AND to_note_id = ? AND link_kind = ? LIMIT 1",
                params![source.id.as_str(), target.id.as_str(), kind_obj.as_str()],
                |r| r.get(0),
            )
            .ok();
        if let Some(link_id) = existing {
            let chosen_source = if kind_obj.as_str() == LinkKind::REFERENCES {
                LinkSource::AutoAdded
            } else {
                LinkSource::Frontmatter
            };
            let env = AddLinkEnvelope {
                vault_id,
                link_id: Some(link_id),
                from_id: source.id.to_string(),
                to_id: target.id.to_string(),
                kind: kind_obj.as_str().to_string(),
                source: chosen_source.as_str().to_string(),
                was_existing: true,
                note_version: source.version,
            };
            return serde_json::to_string(&env)
                .unwrap_or_else(|e| err_payload("add_link.serialize", &e.to_string()));
        }

        // Insert the wikilink into the source's markdown.
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

        let updated = match update_note_with_options(
            &mut vault,
            &source.id,
            source.version,
            UpdateNote {
                content_md: Some(new_md.clone()),
                ..Default::default()
            },
            RenameOptions { rename_links: false },
        ) {
            Ok(n) => n,
            Err(e) => return err_payload("add_link.update", &e.to_string()),
        };

        let embedder = self.state.embedder.clone();
        let embedder_ref = embedder.as_deref();
        if let Err(e) = indexer::reindex_note(
            vault.connection_mut(),
            updated.id.as_str(),
            &new_md,
            embedder_ref,
        ) {
            return err_payload("add_link.index", &e.to_string());
        }

        let link_id: Option<String> = vault.connection_ref().query_row(
            "SELECT id FROM links
                WHERE from_note_id = ? AND to_note_id = ? AND link_kind = ?
                ORDER BY position DESC LIMIT 1",
            params![source.id.as_str(), target.id.as_str(), kind_obj.as_str()],
            |r| r.get(0),
        ).ok();

        let env = AddLinkEnvelope {
            vault_id,
            link_id,
            from_id: source.id.to_string(),
            to_id: target.id.to_string(),
            kind: kind_obj.as_str().to_string(),
            source: chosen_source.as_str().to_string(),
            was_existing: false,
            note_version: updated.version,
        };
        serde_json::to_string(&env)
            .unwrap_or_else(|e| err_payload("add_link.serialize", &e.to_string()))
    }

    /// Create a new note. Indexes it for FTS + (optional) vector search.
    #[tool(description = "Create a new note in the user's vault. \
        Returns the new note_id. Notes you create are tagged 'agent-authored' \
        and 'inbox' by default so the user can review them.")]
    pub async fn create_note(&self, params: Parameters<CreateNoteParams>) -> String {
        let CreateNoteParams {
            content_md,
            title,
            tags: tag_list,
            agent_id,
        } = params.0;

        let mut vault = self.state.vault.lock().await;
        let agent = agent_id.unwrap_or_else(|| "unknown".to_string());
        let now = memex_core::now_unix_ms();
        let frontmatter = serde_json::json!({
            "source": "agent",
            "agent_id": agent,
            "created_at": now,
        });

        let create = CreateNote {
            title,
            content_md: content_md.clone(),
            frontmatter: Some(frontmatter),
        };

        let note = match notes::create_note(&mut vault, create) {
            Ok(n) => n,
            Err(e) => return err_payload("create_note", &e.to_string()),
        };

        let mut all_tags: Vec<String> = tag_list.unwrap_or_default();
        for t in ["inbox", "agent-authored"] {
            if !all_tags.iter().any(|x| x == t) {
                all_tags.push(t.to_string());
            }
        }
        for t in &all_tags {
            let _ = tags::add_tag(&vault, note.id.as_str(), t);
        }

        let embedder = self.state.embedder.clone();
        let embedder_ref = embedder.as_deref();
        if let Err(e) = indexer::reindex_note(
            vault.connection_mut(),
            note.id.as_str(),
            &content_md,
            embedder_ref,
        ) {
            return err_payload("create_note.index", &e.to_string());
        }

        serde_json::to_string(&CreateNoteEnvelope {
            vault_id: vault.vault_id().to_string(),
            note_id: note.id.to_string(),
            version: note.version,
        })
        .unwrap_or_else(|e| err_payload("create_note.serialize", &e.to_string()))
    }
}

#[tool_handler(router = self.tool_router)]
impl ServerHandler for Memex {}

fn group_links_by_kind(
    links: &[core_links::Link],
) -> serde_json::Map<String, serde_json::Value> {
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
    const BUILT_IN: [&str; 4] = ["references", "extends", "contradicts", "example-of"];
    let mut out = serde_json::Map::new();
    let mut user_defined: Vec<String> = Vec::new();
    for k in by_kind.keys() {
        if !BUILT_IN.contains(&k.as_str()) {
            user_defined.push(k.clone());
        }
    }
    user_defined.sort();
    for b in BUILT_IN {
        if let Some(v) = by_kind.remove(b) {
            out.insert(b.to_string(), serde_json::Value::Array(v));
        }
    }
    for k in user_defined {
        if let Some(v) = by_kind.remove(&k) {
            out.insert(k, serde_json::Value::Array(v));
        }
    }
    out
}

fn err_payload(code: &str, message: &str) -> String {
    serde_json::to_string(&serde_json::json!({
        "error": {
            "code": code,
            "message": message,
        }
    }))
    .unwrap_or_else(|_| "{\"error\":{\"code\":\"unknown\",\"message\":\"serialize failed\"}}".into())
}
