//! MCP tools for reviews (architect ruling D7). This area's tools go in the
//! impl below; `Memex::new` already composes `review_router`.

use rmcp::tool_router;

use super::Memex;

#[tool_router(router = review_router, vis = "pub(crate)")]
impl Memex {}
