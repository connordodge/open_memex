//! `memex search` (Spec #59 requirements 34-36): the Command palette's note
//! text search, as `memex_core::note_search::note_search` answers it.

use std::path::PathBuf;
use std::sync::Arc;

use clap::Args;
use memex_core::embedder::{Embedder, FastEmbedder};
use memex_core::note_search::{note_search, SearchEmbedder, Semantic};
use memex_core::Vault;
use serde_json::Value;

use super::echoes::{validate_limit, OTHERS_CAP};
use super::write_json_line;
use crate::state::{build_embedder_in, model_cache_dir};

/// Text embedded to load the model when the query is blank.
const LOAD_PROBE: &str = "memex";

/// `memex search --vault V --query TEXT [--limit N] [--allow-download]`
#[derive(Args, Debug)]
pub struct SearchArgs {
    /// Vault directory.
    #[arg(long)]
    pub vault: PathBuf,
    /// The text to search for, as given (it may start with a hyphen).
    #[arg(long, allow_hyphen_values = true)]
    pub query: String,
    /// Most hits to print, 1 to 20.
    #[arg(long, default_value_t = 8)]
    pub limit: i64,
    /// Download the embedding model (about 130 MB) into the vault if it is not
    /// cached.
    #[arg(long)]
    pub allow_download: bool,
}

/// Prints one line of JSON in the `NoteSearch` shape and exits 0, whatever
/// the meaning state: without `--allow-download` an uncached model answers
/// keyword hits as `model_not_downloaded`; a model that fails to download,
/// load or embed answers them as `unavailable`. A bad `--limit` or vault
/// path is a C1 error.
///
/// An empty or whitespace query embeds nothing, so with an embedder the
/// model is loaded here first (fetched with `--allow-download`): `on` then
/// means the model loaded, and a fetch or load failure answers
/// `unavailable`.
pub fn run(args: SearchArgs) -> anyhow::Result<()> {
    let limit = validate_limit(args.limit)?;
    // Opened first, so a missing vault path creates no model folder and
    // contacts no hub.
    let mut vault = Vault::open(&args.vault)?;
    let embedder: Option<Arc<dyn Embedder>> =
        if args.allow_download || FastEmbedder::is_cached(&model_cache_dir(&args.vault)) {
            Some(build_embedder_in(&args.vault))
        } else {
            None
        };
    let search_embedder = match &embedder {
        Some(e) => SearchEmbedder::Ready(e.as_ref()),
        None => SearchEmbedder::NotDownloaded,
    };
    // `note_search` answers `on` for a blank query without calling the
    // embedder, so the model would never be fetched or loaded.
    let load_failed = args.query.trim().is_empty()
        && embedder
            .as_ref()
            .is_some_and(|e| e.embed_batch(&[LOAD_PROBE.to_string()]).is_err());
    let mut conn = vault.connection_mut();
    let mut out = note_search(&mut conn, &args.query, limit, search_embedder, OTHERS_CAP)?;
    if load_failed {
        out.semantic = Semantic::Unavailable;
    }
    let value: Value = serde_json::to_value(out)?;
    write_json_line(&mut std::io::stdout().lock(), &value)
}
