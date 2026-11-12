//! Agent presence and agent activity (#390).
//!
//! `presence` holds the expiring per-session records under
//! `<vault>/.memex/agents/`; `activity` holds the agent activity log entry.

pub mod activity;
pub mod presence;
