//! MCP tools for vault settings (architect ruling D7). This area's tools go
//! in the impl below; `Memex::new` already composes `settings_router`.

use rmcp::tool_router;

use super::Memex;

#[tool_router(router = settings_router, vis = "pub(crate)")]
impl Memex {}
