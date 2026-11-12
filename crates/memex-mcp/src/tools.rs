//! MCP tool definitions. Each tool returns a JSON-encoded string so callers
//! can parse a stable shape without depending on rmcp's content typing.

use std::sync::Arc;

use memex_core::canvas;
use memex_core::excerpts as core_excerpts;
use memex_core::graph;
use memex_core::indexer;
use memex_core::links::{self as core_links, LinkKind, LinkSource};
use memex_core::notes::{self, CreateNote, NoteId, RenameOptions, UpdateNote};
use memex_core::review as core_review;
use memex_core::search::{self, SearchFilters, SearchMode, SearchOptions};
use memex_core::tags as core_tags;
use memex_core::{Caller, CanvasId, Clock, MemexError, SystemClock};
use rmcp::handler::server::prompt::PromptContext;
use rmcp::handler::server::router::prompt::PromptRouter;
use rmcp::handler::server::router::tool::ToolRouter;
use rmcp::handler::server::tool::ToolCallContext;
use rmcp::handler::server::wrapper::Parameters;
use rmcp::model::{
    CallToolRequestParams, CallToolResult, GetPromptRequestParams, GetPromptResult, Implementation,
    InitializeRequestParams, InitializeResult, ListPromptsResult, ListToolsResult,
    PaginatedRequestParams, ServerCapabilities, ServerInfo, Tool,
};
use rmcp::service::RequestContext;
use rmcp::{tool, tool_router, ErrorData, RoleServer, ServerHandler};
use rusqlite::params;
use schemars::JsonSchema;
use serde::{Deserialize, Serialize};

use crate::activity_log;
use crate::cli::Role;
use crate::md_links;
use crate::presence::{AgentSessions, RequestKind};
use crate::server::request_clock::RequestClock;
use crate::state::AppState;

// One `#[tool_router]` per area (architect ruling D7), composed in `Memex::new`.
pub mod daily;
pub mod excerpts;
pub mod feedback;
pub mod folders;
pub mod meta;
pub mod review;
pub mod settings;
pub mod tags;

#[derive(Clone)]
pub struct Memex {
    pub state: Arc<AppState>,
    tool_router: ToolRouter<Self>,
    prompt_router: PromptRouter<Self>,
    /// The session seam every request is reported to (#445); `None` for
    /// `Memex::new` alone, attached with `with_sessions`.
    pub(crate) sessions: Option<Arc<dyn AgentSessions>>,
}

impl Memex {
    pub fn new(state: Arc<AppState>) -> Self {
        let (tool_router, prompt_router) = Self::routers();
        Self {
            state,
            tool_router,
            prompt_router,
            sessions: None,
        }
    }

    /// The composed tool router (every area's `#[tool_router]`) and prompt
    /// router: the one list of registrations that `Memex::new` serves and
    /// `memex tools` reads (ruling D12).
    pub fn routers() -> (ToolRouter<Self>, PromptRouter<Self>) {
        (
            Self::tool_router()
                + Self::daily_router()
                + Self::excerpts_router()
                + Self::folders_router()
                + Self::review_router()
                + Self::settings_router()
                + Self::feedback_router()
                + Self::tags_router(),
            Self::prompt_router(),
        )
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
    /// What the agent can remove with `untag_note`: its non-system tags.
    pub agent_tags: Vec<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub links: Option<serde_json::Map<String, serde_json::Value>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub backlinks: Option<serde_json::Map<String, serde_json::Value>>,
    /// Review and transclusion fields, merged into the top level (D7).
    #[serde(flatten)]
    pub fields: serde_json::Map<String, serde_json::Value>,
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
    /// Optional role, `daily` or `topic`. Stored in frontmatter as `role`;
    /// any other value is a `role_rule` error.
    #[serde(default)]
    pub role: Option<String>,
}

#[derive(Debug, Serialize)]
pub struct CreateNoteEnvelope {
    pub vault_id: String,
    pub note_id: String,
    pub version: i64,
}

// ---------- canvas tool params/envelopes ----------

#[derive(Debug, Deserialize, JsonSchema)]
pub struct ListCanvasesParams {}

#[derive(Debug, Serialize)]
pub struct CanvasSummaryDto {
    pub canvas_id: String,
    pub title: String,
    pub created_at: i64,
    pub updated_at: i64,
    pub version: i64,
    pub node_count: i64,
}

#[derive(Debug, Serialize)]
pub struct ListCanvasesEnvelope {
    pub vault_id: String,
    pub canvases: Vec<CanvasSummaryDto>,
}

#[derive(Debug, Deserialize, JsonSchema)]
pub struct GetCanvasParams {
    pub canvas_id: String,
}

#[derive(Debug, Serialize)]
pub struct CanvasNodeDto {
    pub note_id: String,
    pub note_title: String,
    pub x: f64,
    pub y: f64,
    pub z_order: i64,
    pub placed_at: i64,
}

#[derive(Debug, Serialize)]
pub struct CanvasEdgeDto {
    pub link_id: String,
    pub from_note_id: String,
    pub to_note_id: String,
    pub link_text: String,
    pub kind: String,
    pub label: Option<String>,
    pub source: String,
    pub position: i64,
}

#[derive(Debug, Serialize)]
pub struct GetCanvasEnvelope {
    pub vault_id: String,
    pub canvas_id: String,
    pub title: String,
    pub created_at: i64,
    pub updated_at: i64,
    pub version: i64,
    pub nodes: Vec<CanvasNodeDto>,
    pub edges: Vec<CanvasEdgeDto>,
}

#[derive(Debug, Deserialize, JsonSchema)]
pub struct CreateCanvasParams {
    pub title: String,
}

#[derive(Debug, Serialize)]
pub struct CreateCanvasEnvelope {
    pub vault_id: String,
    pub canvas_id: String,
    pub title: String,
    pub version: i64,
    pub created_at: i64,
}

#[derive(Debug, Deserialize, JsonSchema)]
pub struct AddToCanvasParams {
    pub canvas_id: String,
    pub note_id: String,
    /// Canvas-space x. Defaults to 0.0.
    #[serde(default)]
    pub x: Option<f64>,
    /// Canvas-space y. Defaults to 0.0.
    #[serde(default)]
    pub y: Option<f64>,
}

#[derive(Debug, Serialize)]
pub struct AddToCanvasEnvelope {
    pub vault_id: String,
    pub canvas_id: String,
    pub note_id: String,
    pub note_title: String,
    pub x: f64,
    pub y: f64,
    pub z_order: i64,
    pub placed_at: i64,
}

#[derive(Debug, Deserialize, JsonSchema)]
pub struct RemoveFromCanvasParams {
    pub canvas_id: String,
    pub note_id: String,
}

#[derive(Debug, Serialize)]
pub struct RemoveFromCanvasEnvelope {
    pub vault_id: String,
    pub canvas_id: String,
    pub note_id: String,
}

#[derive(Debug, Deserialize, JsonSchema)]
pub struct MoveNodeParams {
    pub canvas_id: String,
    pub note_id: String,
    pub x: f64,
    pub y: f64,
    #[serde(default)]
    pub z_order: Option<i64>,
}

#[derive(Debug, Deserialize, JsonSchema)]
pub struct DeleteCanvasParams {
    pub canvas_id: String,
    pub expected_version: i64,
}

#[derive(Debug, Serialize)]
pub struct DeleteCanvasEnvelope {
    pub vault_id: String,
    pub canvas_id: String,
}

#[derive(Debug, Deserialize, JsonSchema)]
pub struct UpdateLinkParams {
    pub link_id: String,
    /// New kind. `None` = keep current.
    #[serde(default)]
    pub kind: Option<String>,
    /// New label. `None` = keep current; non-null sets the label.
    #[serde(default)]
    pub label: Option<String>,
    /// Set to `true` to clear the label. Takes precedence over `label`.
    #[serde(default)]
    pub clear_label: Option<bool>,
}

#[derive(Debug, Serialize)]
pub struct UpdateLinkEnvelope {
    pub vault_id: String,
    pub link_id: String,
    pub from_note_id: String,
    pub to_note_id: Option<String>,
    pub kind: String,
    pub label: Option<String>,
    pub source: String,
    pub position: i64,
}

/// The clock a tool call reads (D6). Over `/mcp` it is the request's
/// [`RequestClock`] (the server's base clock, plus the caller's
/// `X-Memex-UTC-Offset`), from the HTTP request parts rmcp hands the tool.
/// Over stdio there are no parts, and it is the `SystemClock` (local time).
pub(crate) fn call_clock(ctx: &RequestContext<RoleServer>) -> Box<dyn Clock + Send + Sync> {
    match ctx.extensions.get::<axum::http::request::Parts>() {
        Some(parts) => Box::new(RequestClock::from_parts(parts)),
        None => Box::new(SystemClock),
    }
}

#[tool_router(router = tool_router)]
impl Memex {
    /// Hybrid search (FTS + vector) over the user's notes. Returns ranked chunks.
    #[tool(description = "Search the user's notes by keyword or meaning. \
        Returns ranked chunks with snippets. Each result has a stable note_id \
        and chunk_id so you can call get_note for full context. chunk_id is \
        \"\" on a hit expanded from a daily note to a topic note that has no \
        chunks of its own.")]
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
            Err(e) => err_from("search", &e),
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
            Err(e) => return err_from("get_note.invalid_id", &e),
        };
        let vault = self.state.vault.lock().await;
        match notes::get_note(&vault, &id) {
            Ok(n) => {
                let tags = core_tags::tags_for_note(&vault, n.id.as_str()).unwrap_or_default();
                let agent_tags = core_tags::agent_tags_for_note(&vault, &n.id).unwrap_or_default();
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
                let mut fields = match core_review::note_review_fields(&vault, &n) {
                    Ok(m) => m,
                    Err(e) => return err_from("get_note.review", &e),
                };
                match core_excerpts::note_transclusion_fields(&vault, &n) {
                    Ok(m) => fields.extend(m),
                    Err(e) => return err_from("get_note.excerpts", &e),
                }
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
                    agent_tags,
                    links: links_map,
                    backlinks: backlinks_map,
                    fields,
                })
                .unwrap_or_else(|e| err_payload("get_note.serialize", &e.to_string()))
            }
            Err(e) => err_from("get_note", &e),
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
                Err(e) => return err_from("neighbors.invalid_kind", &e),
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
            Err(e) => err_from("neighbors", &e),
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
            Err(e) => return err_from("add_link.invalid_from", &e),
        };
        let to = match NoteId::parse(&to_id) {
            Ok(i) => i,
            Err(e) => return err_from("add_link.invalid_to", &e),
        };
        let kind_obj = match kind.as_deref() {
            Some(k) => match LinkKind::new_user_written(k) {
                Ok(lk) => lk,
                Err(e) => return err_from("add_link.invalid_kind", &e),
            },
            None => LinkKind::references(),
        };

        let mut vault = self.state.vault.lock().await;
        let vault_id = vault.vault_id().to_string();

        let source = match notes::get_note(&vault, &from) {
            Ok(n) => n,
            Err(e) => return err_from("add_link.from_not_found", &e),
        };
        // The marker guard is on the source, before the idempotency answer.
        if let Err(e) = notes::check_agent_write(Caller::Agent, &source.frontmatter, None) {
            return err_from("add_link.update", &e);
        }
        let target = match notes::get_note(&vault, &to) {
            Ok(n) => n,
            Err(e) => return err_from("add_link.to_not_found", &e),
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

        let updated = match notes::update_note_as(
            &mut vault,
            &source.id,
            source.version,
            UpdateNote {
                content_md: Some(new_md),
                ..Default::default()
            },
            RenameOptions { rename_links: false },
            Caller::Agent,
        ) {
            Ok(n) => n,
            Err(e) => return err_from("add_link.update", &e),
        };

        let embedder = self.state.embedder.clone();
        let embedder_ref = embedder.as_deref();
        if let Err(e) = indexer::reindex_note(
            vault.connection_mut(),
            updated.id.as_str(),
            &updated.content_md,
            embedder_ref,
        ) {
            return err_from("add_link.index", &e);
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
    /// A direct call titles a daily note with today in the machine's local
    /// time; the MCP tool is [`Self::create_note_tool`].
    pub async fn create_note(&self, params: Parameters<CreateNoteParams>) -> String {
        self.create_note_impl(params, &SystemClock).await
    }

    /// The `create_note` tool: a daily note's default title is today on the
    /// call's clock ([`call_clock`]).
    #[tool(
        name = "create_note",
        description = "Create a new note in the user's vault. \
        Returns the new note_id. Notes you create are tagged 'agent-authored' \
        and 'inbox' by default so the user can review them."
    )]
    async fn create_note_tool(
        &self,
        params: Parameters<CreateNoteParams>,
        ctx: RequestContext<RoleServer>,
    ) -> String {
        self.create_note_impl(params, &*call_clock(&ctx)).await
    }

    async fn create_note_impl(
        &self,
        params: Parameters<CreateNoteParams>,
        clock: &(dyn Clock + Sync),
    ) -> String {
        let CreateNoteParams {
            content_md,
            title,
            tags: tag_list,
            agent_id,
            role,
        } = params.0;
        // D43: rejected before anything is written.
        if let Some(rejected) = tag_list.as_deref().and_then(tags::invalid_tag_name) {
            return rejected;
        }
        let role = match role {
            None => None,
            Some(r) => match Role::parse(&r) {
                Some(role) => Some(role),
                None => {
                    let msg = format!("role must be `daily` or `topic`, got `{r}`");
                    return err_from("create_note", &MemexError::RoleRule(msg));
                }
            },
        };

        let mut vault = self.state.vault.lock().await;
        let agent = agent_id.unwrap_or_else(|| "unknown".to_string());
        let now = memex_core::now_unix_ms();
        let mut frontmatter = serde_json::json!({
            "source": "agent",
            "agent_id": agent,
            "created_at": now,
        });
        if let Some(r) = role {
            frontmatter["role"] = r.as_str().into();
        }

        // D16 / Q4: an agent may create a daily note only empty, with an ISO
        // title that defaults to today (local). It never adopts (Q2).
        let is_daily = role == Some(Role::Daily);
        let (title, content_md) = if is_daily {
            if !content_md.trim().is_empty() {
                let msg = "an agent may create a daily note only with empty content".to_string();
                return err_from("create_note", &MemexError::MarkerRule(msg));
            }
            let today = || memex_core::daily::today_with_clock(clock).to_string();
            (Some(title.unwrap_or_else(today)), String::new())
        } else {
            (title, content_md)
        };

        let create = CreateNote {
            title,
            content_md,
            frontmatter: Some(frontmatter),
        };

        let note = match notes::create_note_as(&mut vault, create, Caller::Agent) {
            Ok(n) => n,
            Err(e @ MemexError::TitleConflict { .. }) if is_daily => {
                return e.to_error_json().to_string();
            }
            Err(e) => return err_from("create_note", &e),
        };

        let mut all_tags: Vec<String> = tag_list.unwrap_or_default();
        for t in ["inbox", "agent-authored"] {
            if !all_tags.iter().any(|x| x == t) {
                all_tags.push(t.to_string());
            }
        }
        let embedder = self.state.embedder.clone();
        let embedder_ref = embedder.as_deref();
        // D16: agent-origin, with footer text in the same call unless it's a
        // system tag. Every name is valid by now (D43); any other failure to
        // apply a tag doesn't fail the note.
        for t in &all_tags {
            let _ = core_tags::apply_tag(
                &mut vault,
                &note.id,
                t,
                core_tags::TagOrigin::Agent,
                embedder_ref,
            );
        }
        // A footer write moved the note's version and body.
        let note = match notes::get_note(&vault, &note.id) {
            Ok(n) => n,
            Err(e) => return err_from("create_note", &e),
        };

        if let Err(e) = indexer::reindex_note(
            vault.connection_mut(),
            note.id.as_str(),
            &note.content_md,
            embedder_ref,
        ) {
            return err_from("create_note.index", &e);
        }

        serde_json::to_string(&CreateNoteEnvelope {
            vault_id: vault.vault_id().to_string(),
            note_id: note.id.to_string(),
            version: note.version,
        })
        .unwrap_or_else(|e| err_payload("create_note.serialize", &e.to_string()))
    }

    /// List all canvases in the vault.
    #[tool(description = "List every canvas in the user's vault. Returns canvas \
        ids, titles, timestamps, version, and node_count, ordered by most recently \
        updated. Use this to find which canvas to fetch or modify next.")]
    pub async fn list_canvases(&self, _params: Parameters<ListCanvasesParams>) -> String {
        let vault = self.state.vault.lock().await;
        let summaries = match canvas::list_canvases(&vault) {
            Ok(s) => s,
            Err(e) => return err_from("list_canvases", &e),
        };
        let env = ListCanvasesEnvelope {
            vault_id: vault.vault_id().to_string(),
            canvases: summaries
                .into_iter()
                .map(|s| CanvasSummaryDto {
                    canvas_id: s.id.to_string(),
                    title: s.title,
                    created_at: s.created_at,
                    updated_at: s.updated_at,
                    version: s.version,
                    node_count: s.node_count,
                })
                .collect(),
        };
        serde_json::to_string(&env)
            .unwrap_or_else(|e| err_payload("list_canvases.serialize", &e.to_string()))
    }

    /// Read one canvas in full.
    #[tool(description = "Fetch a canvas by id. Returns the canvas metadata, the \
        list of placed notes (with positions), and the list of edges. Edges are \
        wikilinks whose source and target are both placed on this canvas — \
        wikilinks to off-canvas notes are not included.")]
    pub async fn get_canvas(&self, params: Parameters<GetCanvasParams>) -> String {
        let cid = match CanvasId::parse(&params.0.canvas_id) {
            Ok(c) => c,
            Err(e) => return err_from("get_canvas.invalid_id", &e),
        };
        let vault = self.state.vault.lock().await;
        let detail = match canvas::get_canvas(&vault, &cid) {
            Ok(d) => d,
            Err(e) => return err_from("get_canvas", &e),
        };
        let env = GetCanvasEnvelope {
            vault_id: vault.vault_id().to_string(),
            canvas_id: detail.canvas.id.to_string(),
            title: detail.canvas.title,
            created_at: detail.canvas.created_at,
            updated_at: detail.canvas.updated_at,
            version: detail.canvas.version,
            nodes: detail
                .nodes
                .into_iter()
                .map(|n| CanvasNodeDto {
                    note_id: n.note_id,
                    note_title: n.note_title,
                    x: n.x,
                    y: n.y,
                    z_order: n.z_order,
                    placed_at: n.placed_at,
                })
                .collect(),
            edges: detail
                .edges
                .into_iter()
                .map(|e| CanvasEdgeDto {
                    link_id: e.link_id,
                    from_note_id: e.from_note_id,
                    to_note_id: e.to_note_id,
                    link_text: e.link_text,
                    kind: e.link_kind.as_str().to_string(),
                    label: e.label,
                    source: e.source.as_str().to_string(),
                    position: e.position,
                })
                .collect(),
        };
        serde_json::to_string(&env)
            .unwrap_or_else(|e| err_payload("get_canvas.serialize", &e.to_string()))
    }

    /// Create a new, empty canvas.
    #[tool(description = "Create a new canvas with the given title. The title must \
        be unique within the vault. Returns the new canvas_id; use add_to_canvas to \
        place notes on it.")]
    pub async fn create_canvas(&self, params: Parameters<CreateCanvasParams>) -> String {
        let mut vault = self.state.vault.lock().await;
        let c = match canvas::create_canvas(&mut vault, params.0.title) {
            Ok(c) => c,
            Err(memex_core::MemexError::TitleConflict {
                existing_id,
                attempted_title,
            }) => {
                return err_payload(
                    "create_canvas.title_conflict",
                    &format!(
                        "title '{attempted_title}' already used by canvas {existing_id}"
                    ),
                );
            }
            Err(e) => return err_from("create_canvas", &e),
        };
        let env = CreateCanvasEnvelope {
            vault_id: vault.vault_id().to_string(),
            canvas_id: c.id.to_string(),
            title: c.title,
            version: c.version,
            created_at: c.created_at,
        };
        serde_json::to_string(&env)
            .unwrap_or_else(|e| err_payload("create_canvas.serialize", &e.to_string()))
    }

    /// Place a note on a canvas (idempotent).
    #[tool(
        description = "Place a note on a canvas at the given (x, y) coordinates. \
        Idempotent on (canvas_id, note_id): if the note is already placed, returns \
        the existing placement and position is unchanged. Defaults to (0, 0) when \
        x/y are omitted. Returns the placement and added (false when it is the \
        existing one)."
    )]
    pub async fn add_to_canvas(&self, params: Parameters<AddToCanvasParams>) -> String {
        let AddToCanvasParams {
            canvas_id,
            note_id,
            x,
            y,
        } = params.0;
        let cid = match CanvasId::parse(&canvas_id) {
            Ok(c) => c,
            Err(e) => return err_from("add_to_canvas.invalid_canvas", &e),
        };
        if let Err(e) = NoteId::parse(&note_id) {
            return err_from("add_to_canvas.invalid_note", &e);
        }
        let mut vault = self.state.vault.lock().await;
        let (node, added) = match canvas::add_to_canvas_added(
            &mut vault,
            &cid,
            &note_id,
            x.unwrap_or(0.0),
            y.unwrap_or(0.0),
            &SystemClock,
        ) {
            Ok(n) => n,
            Err(e) => return err_from("add_to_canvas", &e),
        };
        /// The placement and `added` (Spec #390 req 8).
        #[derive(Serialize)]
        struct Placed {
            #[serde(flatten)]
            env: AddToCanvasEnvelope,
            added: bool,
        }
        let env = AddToCanvasEnvelope {
            vault_id: vault.vault_id().to_string(),
            canvas_id: node.canvas_id.to_string(),
            note_id: node.note_id,
            note_title: node.note_title,
            x: node.x,
            y: node.y,
            z_order: node.z_order,
            placed_at: node.placed_at,
        };
        serde_json::to_string(&Placed { env, added })
            .unwrap_or_else(|e| err_payload("add_to_canvas.serialize", &e.to_string()))
    }

    /// Remove a note's placement from a canvas. No-op if not placed.
    #[tool(description = "Remove a note's placement from a canvas. The note and \
        every wikilink in it are untouched — only the placement record is removed. \
        Idempotent: calling on an unplaced note is a no-op. Returns vault_id, \
        canvas_id, note_id and removed (false when the note wasn't placed).")]
    pub async fn remove_from_canvas(
        &self,
        params: Parameters<RemoveFromCanvasParams>,
    ) -> String {
        let RemoveFromCanvasParams { canvas_id, note_id } = params.0;
        let cid = match CanvasId::parse(&canvas_id) {
            Ok(c) => c,
            Err(e) => return err_from("remove_from_canvas.invalid_canvas", &e),
        };
        let mut vault = self.state.vault.lock().await;
        let removed =
            match canvas::remove_from_canvas_removed(&mut vault, &cid, &note_id, &SystemClock) {
                Ok(removed) => removed,
                Err(e) => return err_from("remove_from_canvas", &e),
            };
        /// The envelope and `removed` (Spec #390 req 8).
        #[derive(Serialize)]
        struct Removed {
            #[serde(flatten)]
            env: RemoveFromCanvasEnvelope,
            removed: bool,
        }
        let env = RemoveFromCanvasEnvelope {
            vault_id: vault.vault_id().to_string(),
            canvas_id,
            note_id,
        };
        serde_json::to_string(&Removed { env, removed })
            .unwrap_or_else(|e| err_payload("remove_from_canvas.serialize", &e.to_string()))
    }

    /// Move a placed node on the canvas.
    #[tool(description = "Move a placed node to new (x, y) coordinates on its \
        canvas. Optionally updates z_order. Errors if the note is not placed on \
        this canvas. Returns the placement and changed (false when x, y and the \
        given z_order equal the current ones).")]
    pub async fn move_node(&self, params: Parameters<MoveNodeParams>) -> String {
        let MoveNodeParams {
            canvas_id,
            note_id,
            x,
            y,
            z_order,
        } = params.0;
        let cid = match CanvasId::parse(&canvas_id) {
            Ok(c) => c,
            Err(e) => return err_from("move_node.invalid_canvas", &e),
        };
        let mut vault = self.state.vault.lock().await;
        let (node, changed) = match canvas::move_node_changed(
            &mut vault,
            &cid,
            &note_id,
            x,
            y,
            z_order,
            &SystemClock,
        ) {
            Ok(n) => n,
            Err(e) => return err_from("move_node", &e),
        };
        /// The placement and `changed` (Spec #390 req 8).
        #[derive(Serialize)]
        struct Moved {
            #[serde(flatten)]
            env: AddToCanvasEnvelope,
            changed: bool,
        }
        let env = AddToCanvasEnvelope {
            vault_id: vault.vault_id().to_string(),
            canvas_id: node.canvas_id.to_string(),
            note_id: node.note_id,
            note_title: node.note_title,
            x: node.x,
            y: node.y,
            z_order: node.z_order,
            placed_at: node.placed_at,
        };
        serde_json::to_string(&Moved { env, changed })
            .unwrap_or_else(|e| err_payload("move_node.serialize", &e.to_string()))
    }

    /// Delete a canvas. Notes and links are not touched.
    #[tool(description = "Delete a canvas by id, honoring optimistic concurrency \
        via `expected_version`. Cascades placements only — the underlying notes \
        and their wikilinks are unchanged.")]
    pub async fn delete_canvas(&self, params: Parameters<DeleteCanvasParams>) -> String {
        let cid = match CanvasId::parse(&params.0.canvas_id) {
            Ok(c) => c,
            Err(e) => return err_from("delete_canvas.invalid_id", &e),
        };
        let mut vault = self.state.vault.lock().await;
        if let Err(e) = canvas::delete_canvas(&mut vault, &cid, params.0.expected_version) {
            return err_from("delete_canvas", &e);
        }
        let env = DeleteCanvasEnvelope {
            vault_id: vault.vault_id().to_string(),
            canvas_id: cid.to_string(),
        };
        serde_json::to_string(&env)
            .unwrap_or_else(|e| err_payload("delete_canvas.serialize", &e.to_string()))
    }

    /// Update the `kind` and/or `label` of an existing wikilink in place.
    #[tool(
        description = "Edit a single wikilink's kind and/or label in place. Pass \
        `clear_label=true` to remove the label. Frontmatter links accept label \
        changes only — changing the kind of a frontmatter-bound wikilink returns \
        an error in v1. Returns the link and changed (false when every given \
        value equals the current one: nothing is written)."
    )]
    pub async fn update_link(&self, params: Parameters<UpdateLinkParams>) -> String {
        let UpdateLinkParams {
            link_id,
            kind,
            label,
            clear_label,
        } = params.0;
        let new_kind = match kind {
            Some(k) => match LinkKind::new_user_written(&k) {
                Ok(lk) => Some(lk),
                Err(e) => return err_from("update_link.invalid_kind", &e),
            },
            None => None,
        };
        let new_label: Option<Option<String>> = if clear_label.unwrap_or(false) {
            Some(None)
        } else {
            label.map(Some)
        };
        let mut vault = self.state.vault.lock().await;
        // The marker guard is on the source, before update_link_as answers a
        // no-op edit without saving.
        let source = core_links::get_link(&vault, &link_id)
            .and_then(|link| NoteId::parse(&link.from_note_id))
            .and_then(|id| notes::get_note(&vault, &id));
        if let Ok(source) = source {
            if let Err(e) = notes::check_agent_write(Caller::Agent, &source.frontmatter, None) {
                return err_from("update_link", &e);
            }
        }
        let (link, changed) = match core_links::update_link_changed(
            &mut vault,
            &link_id,
            core_links::UpdateLink {
                new_kind,
                new_label,
            },
            Caller::Agent,
        ) {
            Ok(l) => l,
            Err(e) => return err_from("update_link", &e),
        };
        /// The link and `changed` (Spec #390 req 8).
        #[derive(Serialize)]
        struct Updated {
            #[serde(flatten)]
            env: UpdateLinkEnvelope,
            changed: bool,
        }
        let env = UpdateLinkEnvelope {
            vault_id: vault.vault_id().to_string(),
            link_id: link.id,
            from_note_id: link.from_note_id,
            to_note_id: link.to_note_id,
            kind: link.link_kind.as_str().to_string(),
            label: link.label,
            source: link.source.as_str().to_string(),
            position: link.position,
        };
        serde_json::to_string(&Updated { env, changed })
            .unwrap_or_else(|e| err_payload("update_link.serialize", &e.to_string()))
    }
}

impl Memex {
    /// Tells the session seam, if any, about a request that is not a tool
    /// call, before it runs.
    fn report_other(&self, ctx: &RequestContext<RoleServer>) {
        if let Some(sessions) = &self.sessions {
            sessions.on_request(ctx, RequestKind::Other);
        }
    }
}

// Tools and prompts (D18), written out from what `#[tool_handler]` and
// `#[prompt_handler]` generated, so each request is reported to the session
// seam (#445) before it runs. `get_info`, `tools/list` and the prompts are
// unchanged.
impl ServerHandler for Memex {
    fn get_info(&self) -> ServerInfo {
        ServerInfo::new(
            ServerCapabilities::builder()
                .enable_tools()
                .enable_prompts()
                .build(),
        )
        .with_server_info(Implementation::from_build_env())
    }

    async fn initialize(
        &self,
        request: InitializeRequestParams,
        context: RequestContext<RoleServer>,
    ) -> Result<InitializeResult, ErrorData> {
        self.report_other(&context);
        if context.peer.peer_info().is_none() {
            context.peer.set_peer_info(request);
        }
        Ok(self.get_info())
    }

    async fn ping(&self, context: RequestContext<RoleServer>) -> Result<(), ErrorData> {
        self.report_other(&context);
        Ok(())
    }

    async fn call_tool(
        &self,
        request: CallToolRequestParams,
        context: RequestContext<RoleServer>,
    ) -> Result<CallToolResult, ErrorData> {
        let session = self
            .sessions
            .as_ref()
            .and_then(|s| s.on_request(&context, RequestKind::ToolCall));
        // The activity log hook (#451): only a write with a session is logged.
        let Some(session) = session.filter(|_| meta::is_write(&request.name)) else {
            let tcc = ToolCallContext::new(self, request, context);
            return self.tool_router.call(tcc).await;
        };
        let tool = request.name.to_string();
        let params = activity_log::params_of(&request);
        let clock = call_clock(&context);
        let pre = {
            let vault = self.state.vault.lock().await;
            activity_log::pre_snapshot(vault.connection_ref(), &tool, &params)
        };
        let tcc = ToolCallContext::new(self, request, context);
        let result = self.tool_router.call(tcc).await;
        if let Ok(done) = &result {
            let vault = self.state.vault.lock().await;
            activity_log::record(
                vault.connection_ref(),
                &session,
                &tool,
                &params,
                &pre,
                done,
                clock.now_ms(),
            );
        }
        result
    }

    async fn list_tools(
        &self,
        _request: Option<PaginatedRequestParams>,
        context: RequestContext<RoleServer>,
    ) -> Result<ListToolsResult, ErrorData> {
        self.report_other(&context);
        Ok(ListToolsResult {
            tools: self.tool_router.list_all(),
            meta: None,
            next_cursor: None,
        })
    }

    fn get_tool(&self, name: &str) -> Option<Tool> {
        self.tool_router.get(name).cloned()
    }

    async fn list_prompts(
        &self,
        _request: Option<PaginatedRequestParams>,
        context: RequestContext<RoleServer>,
    ) -> Result<ListPromptsResult, ErrorData> {
        self.report_other(&context);
        Ok(ListPromptsResult {
            prompts: self.prompt_router.list_all(),
            meta: None,
            next_cursor: None,
        })
    }

    async fn get_prompt(
        &self,
        request: GetPromptRequestParams,
        context: RequestContext<RoleServer>,
    ) -> Result<GetPromptResult, ErrorData> {
        self.report_other(&context);
        let prompt_context = PromptContext::new(self, request.name, request.arguments, context);
        self.prompt_router.get_prompt(prompt_context).await
    }
}

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

/// The tool error for a core failure (architect ruling D4): a rule error
/// returns its CONTRACTS C1 object with the rule code; any other error keeps
/// today's `op` code.
fn err_from(op: &str, e: &MemexError) -> String {
    let is_rule = matches!(
        e,
        MemexError::DailyNoteExists { .. }
            | MemexError::MarkerRule(_)
            | MemexError::RoleRule(_)
            | MemexError::PinnedRule { .. }
            | MemexError::DepthExceeded { .. }
            | MemexError::ChangeEntriesInvalid(_)
            | MemexError::ReviewStale { .. }
            | MemexError::NameConflict(_)
            | MemexError::FolderCycle(_)
            | MemexError::InvalidDate(_)
            | MemexError::BlockNotFound(_)
            | MemexError::SettingInvalid(_)
            | MemexError::GuideRule(_)
    );
    if is_rule {
        e.to_error_json().to_string()
    } else {
        err_payload(op, &e.to_string())
    }
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
