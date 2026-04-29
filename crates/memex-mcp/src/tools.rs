//! MCP tool definitions. Each tool returns a JSON-encoded string so callers
//! can parse a stable shape without depending on rmcp's content typing.

use std::sync::Arc;

use memex_core::indexer;
use memex_core::notes::{self, CreateNote, NoteId};
use memex_core::search::{self, SearchFilters, SearchMode, SearchOptions};
use memex_core::tags;
use rmcp::handler::server::router::tool::ToolRouter;
use rmcp::handler::server::wrapper::Parameters;
use rmcp::{tool, tool_handler, tool_router, ServerHandler};
use schemars::JsonSchema;
use serde::{Deserialize, Serialize};

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
    /// If true, include backlinks. Currently a placeholder until linking lands.
    #[serde(default)]
    #[allow(dead_code)]
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
        Use this after `search` to read the full content of a relevant note.")]
    pub async fn get_note(&self, params: Parameters<GetNoteParams>) -> String {
        let GetNoteParams { note_id, .. } = params.0;
        let id = match NoteId::parse(&note_id) {
            Ok(i) => i,
            Err(e) => return err_payload("get_note.invalid_id", &e.to_string()),
        };
        let vault = self.state.vault.lock().await;
        match notes::get_note(&vault, &id) {
            Ok(n) => {
                let tags = tags::tags_for_note(&vault, n.id.as_str()).unwrap_or_default();
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
                })
                .unwrap_or_else(|e| err_payload("get_note.serialize", &e.to_string()))
            }
            Err(e) => err_payload("get_note", &e.to_string()),
        }
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

fn err_payload(code: &str, message: &str) -> String {
    serde_json::to_string(&serde_json::json!({
        "error": {
            "code": code,
            "message": message,
        }
    }))
    .unwrap_or_else(|_| "{\"error\":{\"code\":\"unknown\",\"message\":\"serialize failed\"}}".into())
}
