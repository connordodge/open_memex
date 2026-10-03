//! MCP prompts and the `memex prompt` texts (filled by #16).
//!
//! Architect ruling D18: each prompt's text exists exactly once, here. The MCP
//! prompts (`review_daily_notes`, `capture`) and `memex prompt review|capture`
//! all serve these constants unchanged.

/// The text of the `review_daily_notes` MCP prompt and `memex prompt review`.
pub const REVIEW_DAILY_NOTES: &str = "";

/// The text of the `capture` MCP prompt and `memex prompt capture`.
pub const CAPTURE: &str = "";
