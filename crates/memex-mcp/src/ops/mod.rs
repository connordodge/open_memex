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
pub mod feedback;
pub mod folder;
pub mod footer;
pub mod guide;
pub mod links;
pub mod notes;
pub mod prompt;
pub mod settings;
pub mod tags;
pub mod words;

pub use memex_core::embedder::Embedder;
pub use memex_core::Clock;

use memex_core::MemexError;

use crate::cli::InvalidArgument;

/// A core failure with the C1 code it has on the person path: the core's
/// `Io(InvalidInput)` (a bad tag name, a body tag to remove, a self-chip) is
/// `invalid_argument`, and any other failure keeps its own code.
pub(crate) fn invalid_input_as_argument(err: MemexError) -> anyhow::Error {
    match err {
        MemexError::Io(e) if e.kind() == std::io::ErrorKind::InvalidInput => {
            InvalidArgument(e.to_string()).into()
        }
        other => other.into(),
    }
}
