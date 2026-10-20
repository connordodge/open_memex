//! Person-side operations shared by the `memex` CLI and the app API
//! (architect ruling D2).
//!
//! Each op is `fn(&mut Vault, Input, &dyn Clock, Option<&dyn Embedder>) ->
//! anyhow::Result<Output>`. It takes an open vault (never a path), acts as
//! `Caller::Person`, threads `clock` into every core call that takes one and
//! reindexes with `embedder` when it writes. It returns a typed `Serialize`
//! struct: the CLI prints it and the app API serializes the same struct, so
//! the two can't diverge. Errors map through [`crate::cli::error_json`] to the
//! same C1 object as the CLI prints.
//!
//! MCP tools are not migrated: `tools.rs` and `tools/*` keep their own
//! agent-path code.

pub mod canvas;
pub mod excerpt;
pub mod folder;
pub mod footer;
pub mod links;
pub mod notes;
pub mod prompt;
pub mod settings;

pub use memex_core::embedder::Embedder;
pub use memex_core::Clock;
