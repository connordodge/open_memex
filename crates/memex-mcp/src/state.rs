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
    build_embedder_in(vault_path)
}

/// The model cache directory for a vault root: `<root>/.memex/models`.
/// It only computes the path; nothing is created.
pub fn model_cache_dir(root: &Path) -> PathBuf {
    root.join(".memex").join("models")
}

/// Build a FastEmbedder backed by BGE-small-en-v1.5 whose model cache is
/// `<root>/.memex/models` (created here). Nothing is downloaded until the
/// first embed. The vault server builds one for its whole vault root and
/// shares it between every served vault.
pub fn build_embedder_in(root: &Path) -> Arc<dyn Embedder> {
    let cache_dir = model_cache_dir(root);
    std::fs::create_dir_all(&cache_dir).ok();
    Arc::new(FastEmbedder::bge_small_en_v15(Some(cache_dir)))
}
