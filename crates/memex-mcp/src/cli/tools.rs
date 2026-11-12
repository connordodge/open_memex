//! `memex tools` (Spec #394, rulings D11 and D12): the MCP tools and prompts
//! this binary serves, as one JSON line. `GET /api/v1/tools` returns the same
//! [`body`].

use anyhow::Context;
use serde_json::{json, Value};

use crate::tools::meta;
use crate::tools::Memex;

/// `{"tools": [{name, summary, group, writes}], "prompts": [{name, summary}]}`.
/// Names and their order come from the composed routers' `list_all()`; every
/// other field comes from the [`meta`] row of that name. A registered tool or
/// prompt without a row is an `internal` error.
pub fn body() -> anyhow::Result<Value> {
    let (tool_router, prompt_router) = Memex::routers();
    let tools = tool_router
        .list_all()
        .iter()
        .map(|t| {
            let row = meta::tool(&t.name)
                .with_context(|| format!("tool {} has no metadata row", t.name))?;
            Ok(json!({
                "name": row.name,
                "summary": row.summary,
                "group": row.group.id(),
                "writes": row.writes,
            }))
        })
        .collect::<anyhow::Result<Vec<Value>>>()?;
    let prompts = prompt_router
        .list_all()
        .iter()
        .map(|p| {
            let row = meta::prompt(&p.name)
                .with_context(|| format!("prompt {} has no metadata row", p.name))?;
            Ok(json!({ "name": row.name, "summary": row.summary }))
        })
        .collect::<anyhow::Result<Vec<Value>>>()?;
    Ok(json!({ "tools": tools, "prompts": prompts }))
}

/// Prints [`body`] on stdout as one line of compact JSON.
pub fn run() -> anyhow::Result<()> {
    let value = body()?;
    super::write_json_line(&mut std::io::stdout().lock(), &value)
}
