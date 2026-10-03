//! Caller identity (architect ruling D3).
//!
//! Every write that a later rule may guard (the marker rule, pinning,
//! append-only change entries) has an agent-aware entry point taking a
//! [`Caller`]: `notes::create_note_as`, `notes::update_note_as` and
//! `links::update_link_as`. The pre-existing person-path functions keep their
//! signatures and delegate with [`Caller::Person`]. Caller identity is always a
//! parameter, never a struct field.

/// Who is making a write.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Caller {
    /// The person, through the app or the CLI.
    Person,
    /// An agent, through the MCP server.
    Agent,
}
