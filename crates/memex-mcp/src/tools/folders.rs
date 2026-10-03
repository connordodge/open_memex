//! MCP tools for Smart Folders (architect ruling D7). This area's tools go in
//! the impl below; `Memex::new` already composes `folders_router`.

use rmcp::tool_router;

use super::Memex;

#[tool_router(router = folders_router, vis = "pub(crate)")]
impl Memex {}
