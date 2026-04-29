use std::path::{Path, PathBuf};
use std::sync::Arc;

use memex_core::embedder::{Embedder, FastEmbedder};
use memex_core::Vault;
use tokio::sync::Mutex;

/// Shared state held by the MCP server. The Vault is held under a mutex
/// because notes::* and indexer::* take `&mut Connection`.
#[derive(Clone)]
pub struct AppState {
    pub vault: Arc<Mutex<Vault>>,
    #[allow(dead_code)]
    pub vault_path: PathBuf,
    pub embedder: Option<Arc<dyn Embedder>>,
}

impl AppState {
    pub fn new(
        vault: Vault,
        vault_path: PathBuf,
        embedder: Option<Arc<dyn Embedder>>,
    ) -> Self {
        Self {
            vault: Arc::new(Mutex::new(vault)),
            vault_path,
            embedder,
        }
    }

    pub fn embedder_ref(&self) -> Option<&dyn Embedder> {
        self.embedder.as_deref()
    }
}

/// Build a FastEmbedder backed by BGE-small-en-v1.5. The cache directory is
/// scoped to the vault so multi-vault setups don't collide and the user can
/// nuke it cheaply.
pub fn build_default_embedder(vault_path: &Path) -> Arc<dyn Embedder> {
    let cache_dir = vault_path.join(".memex").join("models");
    std::fs::create_dir_all(&cache_dir).ok();
    Arc::new(FastEmbedder::bge_small_en_v15(Some(cache_dir)))
}
