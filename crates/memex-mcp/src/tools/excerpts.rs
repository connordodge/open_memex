//! MCP tools for excerpts (architect ruling D7). This area's tools go in the
//! impl below; `Memex::new` already composes `excerpts_router`.

use rmcp::tool_router;

use super::Memex;

#[tool_router(router = excerpts_router, vis = "pub(crate)")]
impl Memex {}
