//! MCP tools for daily notes (architect ruling D7). This area's tools go in
//! the impl below; `Memex::new` already composes `daily_router`.

use rmcp::tool_router;

use super::Memex;

#[tool_router(router = daily_router, vis = "pub(crate)")]
impl Memex {}
