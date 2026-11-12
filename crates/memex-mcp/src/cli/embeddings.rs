//! `memex embeddings status` (Spec #394, rulings D6, D39 and D40): how many
//! chunks have a vector and whether the embedding model is in the cache, as
//! one JSON line. `GET /api/v1/embeddings` returns the same [`body`].
//!
//! Both are reads: they never build an embedder, load or download the model,
//! or create the cache directory.

use std::fs;
use std::path::{Path, PathBuf};

use clap::{Args, Subcommand};
use memex_core::embedder::FastEmbedder;
use memex_core::vectors::EmbeddingCounts;
use memex_core::Vault;
use serde_json::{json, Value};

use crate::state::model_cache_dir;

/// `memex embeddings <command>`
#[derive(Args, Debug)]
pub struct EmbeddingsArgs {
    #[command(subcommand)]
    pub command: EmbeddingsCommand,
}

#[derive(Subcommand, Debug)]
pub enum EmbeddingsCommand {
    /// Print embedding coverage and model cache status as JSON.
    Status(EmbeddingsStatusArgs),
}

/// `memex embeddings status --vault V`
#[derive(Args, Debug)]
pub struct EmbeddingsStatusArgs {
    /// Vault directory.
    #[arg(long)]
    pub vault: PathBuf,
}

pub fn run(args: EmbeddingsArgs) -> anyhow::Result<()> {
    match args.command {
        EmbeddingsCommand::Status(a) => status(a),
    }
}

/// Prints [`body`] for the vault, with `server_embeddings` null and the
/// vault's own model cache dir.
fn status(args: EmbeddingsStatusArgs) -> anyhow::Result<()> {
    let vault = Vault::open(&args.vault)?;
    let counts = memex_core::vectors::embedding_counts(vault.connection_ref())?;
    let value = body(None, counts, &model_cache_dir(&args.vault));
    super::write_json_line(&mut std::io::stdout().lock(), &value)
}

/// `{"server_embeddings", "chunks", "embedded", "model_cached",
/// "model_bytes"}`. The model fields describe the directory fastembed loads
/// from when given `cache_dir` (`$HF_HOME` when set), so `model_cached` and
/// `model_bytes` always measure the same place.
pub fn body(server_embeddings: Option<bool>, counts: EmbeddingCounts, cache_dir: &Path) -> Value {
    json!({
        "server_embeddings": server_embeddings,
        "chunks": counts.chunks,
        "embedded": counts.embedded,
        "model_cached": FastEmbedder::is_cached(cache_dir),
        "model_bytes": dir_bytes(&FastEmbedder::load_cache_dir(cache_dir)),
    })
}

/// The summed lengths of the regular files at any depth under `dir`.
/// Symlinks are never followed, so a snapshot link and the blob it points
/// at count once. A missing `dir` is 0; an entry that cannot be read is
/// skipped.
fn dir_bytes(dir: &Path) -> u64 {
    let Ok(entries) = fs::read_dir(dir) else {
        return 0;
    };
    entries
        .flatten()
        .map(|entry| {
            let path = entry.path();
            match fs::symlink_metadata(&path) {
                Ok(meta) if meta.is_file() => meta.len(),
                Ok(meta) if meta.is_dir() => dir_bytes(&path),
                _ => 0,
            }
        })
        .sum()
}
