//! The vault server: `memex serve --root <dir> --listen <host:port>`.
//!
//! One axum router serves every route under one bearer-token layer (D7).
//! This file is the red-commit skeleton for WI #71; the implementer fills
//! `router()` and adds `run()`, `auth`, `token`, `log` and `bridge`.

use std::path::{Path, PathBuf};

use axum::Router;

pub mod error;

/// The app API version this server speaks (the app's `kApiVersion`, D17).
pub const API_VERSION: u32 = 1;

/// What the vault server needs to build its router. The token is already
/// resolved and trimmed; `router()` never reads the environment.
#[derive(Clone)]
pub struct ServerConfig {
    root: PathBuf,
    token: String,
    with_embeddings: bool,
}

impl ServerConfig {
    /// A config serving the vault root `root`, accepting only `token`.
    pub fn new(root: impl Into<PathBuf>, token: impl Into<String>) -> Self {
        Self {
            root: root.into(),
            token: token.into(),
            with_embeddings: false,
        }
    }

    /// Whether every served vault uses real embeddings (default: no).
    pub fn with_embeddings(mut self, on: bool) -> Self {
        self.with_embeddings = on;
        self
    }

    /// The vault root.
    pub fn root(&self) -> &Path {
        &self.root
    }
}

/// The whole vault server: every route, then the auth layer, the body limit
/// and the access log (D7).
pub fn router(config: ServerConfig) -> Router {
    drop((config.root, config.token, config.with_embeddings));
    Router::new()
}
