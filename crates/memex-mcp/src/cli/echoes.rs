//! `memex echoes` (Spec #391 req 17, #423): passages in other, unlinked
//! notes that are close to one note, as `memex_core::echoes::echoes`
//! answers them.

use std::path::{Path, PathBuf};
use std::sync::Arc;

use clap::Args;
use memex_core::echoes::echoes;
use memex_core::embedder::{Embedder, FastEmbedder};
use memex_core::{MemexError, Vault};
use serde_json::Value;

use super::{write_json_line, InvalidArgument};
use crate::state::{build_embedder_in, model_cache_dir};

/// The fewest echoes `--limit` (and the route's `limit`) may ask for.
pub const LIMIT_MIN: i64 = 1;
/// The most echoes `--limit` (and the route's `limit`) may ask for.
pub const LIMIT_MAX: i64 = 20;
/// The CLI's `others_cap`: other notes' unembedded chunks one read embeds
/// (Spec #391 req 11.1, "64 locally").
const OTHERS_CAP: usize = 64;

/// `memex echoes --vault V --note-id ID [--limit N] [--allow-download]`
#[derive(Args, Debug)]
pub struct EchoesArgs {
    /// Vault directory.
    #[arg(long)]
    pub vault: PathBuf,
    /// Note id (ULID).
    #[arg(long)]
    pub note_id: String,
    /// Most echoes to print, 1 to 20.
    #[arg(long, default_value_t = 8)]
    pub limit: i64,
    /// Download the embedding model (about 130 MB) into the vault if it is not
    /// cached.
    #[arg(long)]
    pub allow_download: bool,
}

/// `limit` as a count when it is within 1 to 20, else `invalid_argument`
/// (`invalid limit: <n> (1 to 20)`). The CLI and the vault server route
/// share it.
pub fn validate_limit(limit: i64) -> Result<usize, InvalidArgument> {
    if (LIMIT_MIN..=LIMIT_MAX).contains(&limit) {
        Ok(limit as usize)
    } else {
        Err(InvalidArgument(format!(
            "invalid limit: {limit} ({LIMIT_MIN} to {LIMIT_MAX})"
        )))
    }
}

pub fn run(args: EchoesArgs) -> anyhow::Result<()> {
    let limit = validate_limit(args.limit)?;
    let mut vault = Vault::open(&args.vault)?;
    let embedder: Arc<dyn Embedder> = if args.allow_download {
        build_embedder_in(&args.vault)
    } else {
        Arc::new(CachedOnly::new(&args.vault))
    };
    let mut conn = vault.connection_mut();
    let out = echoes(
        &mut conn,
        embedder.as_ref(),
        &args.note_id,
        limit,
        OTHERS_CAP,
    )?;
    let value: Value = serde_json::to_value(out)?;
    write_json_line(&mut std::io::stdout().lock(), &value)
}

/// The vault's embedder without `--allow-download`: a batch with any text
/// fails with `model_not_downloaded` while the model is not cached in
/// `model_cache_dir(<vault>)`, before fastembed (and so the network) is
/// reached. A read that embeds nothing never checks, so it needs no model.
struct CachedOnly {
    cache_dir: PathBuf,
    inner: FastEmbedder,
}

impl CachedOnly {
    fn new(vault: &Path) -> Self {
        let cache_dir = model_cache_dir(vault);
        Self {
            inner: FastEmbedder::bge_small_en_v15(Some(cache_dir.clone())),
            cache_dir,
        }
    }
}

impl Embedder for CachedOnly {
    fn model_version(&self) -> &str {
        self.inner.model_version()
    }

    fn dimension(&self) -> usize {
        self.inner.dimension()
    }

    fn embed_batch(&self, texts: &[String]) -> memex_core::Result<Vec<Vec<f32>>> {
        if !texts.is_empty() && !FastEmbedder::is_cached(&self.cache_dir) {
            return Err(MemexError::ModelNotDownloaded);
        }
        self.inner.embed_batch(texts)
    }
}
