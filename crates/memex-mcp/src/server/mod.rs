//! The vault server: `memex serve --root <dir> --listen <host:port>`.
//!
//! One axum router serves every route under one bearer-token layer (D7).
//! From the outside in, a request passes the access log, the auth layer and
//! the 8 MiB body limit before it reaches a route.

use std::path::{Path, PathBuf};

use anyhow::{Context, Result};
use axum::extract::DefaultBodyLimit;
use axum::http::header::CONTENT_TYPE;
use axum::http::StatusCode;
use axum::middleware::{from_fn, from_fn_with_state, map_response};
use axum::response::{IntoResponse, Response};
use axum::routing::get;
use axum::{Json, Router};
use memex_core::fs_guard::{self, FsInfo};
use memex_core::MemexError;
use serde_json::{json, Value};
use tower_http::limit::RequestBodyLimitLayer;

use crate::cli::InvalidArgument;

pub mod auth;
pub mod bridge;
pub mod error;
pub mod log;
pub mod token;

use error::ApiError;

/// The app API version this server speaks (the app's `kApiVersion`, D17).
pub const API_VERSION: u32 = 1;

/// The largest request body the server reads (req 19): 8 MiB.
pub const BODY_LIMIT: usize = 8 * 1024 * 1024;

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

    /// Whether served vaults use real embeddings.
    pub fn embeddings_enabled(&self) -> bool {
        self.with_embeddings
    }
}

/// The whole vault server: every route, then the auth layer, the body limit
/// and the access log (D7).
pub fn router(config: ServerConfig) -> Router {
    let token = auth::AccessToken::new(&config.token);
    Router::new()
        .route("/api/v1/info", get(info))
        .fallback(not_found)
        .method_not_allowed_fallback(method_not_allowed)
        // Every route, nest and fallback goes above this line, so that the
        // layers below wrap all of them. Listed inside out.
        .layer(DefaultBodyLimit::disable())
        .layer(RequestBodyLimitLayer::new(BODY_LIMIT))
        .layer(map_response(c1_payload_too_large))
        .layer(from_fn_with_state(token, auth::require_token))
        .layer(from_fn(log::access_log))
}

/// `GET /api/v1/info`.
async fn info() -> Json<Value> {
    Json(json!({
        "server_version": env!("CARGO_PKG_VERSION"),
        "api_version": API_VERSION,
    }))
}

/// Any path no route serves: 404 `not_found`.
async fn not_found() -> ApiError {
    ApiError::from(MemexError::NotFound("no route for this path".into()))
}

/// A known path asked with a method no route there serves: 405
/// `method_not_allowed`.
async fn method_not_allowed() -> ApiError {
    ApiError::new(
        "method_not_allowed",
        "this path does not serve this HTTP method",
    )
}

/// Gives the body limit's own 413 (and any other 413 without a JSON body)
/// the C1 `payload_too_large` body.
async fn c1_payload_too_large(resp: Response) -> Response {
    let is_json = resp
        .headers()
        .get(CONTENT_TYPE)
        .and_then(|v| v.to_str().ok())
        .is_some_and(|ct| ct.starts_with("application/json"));
    if resp.status() == StatusCode::PAYLOAD_TOO_LARGE && !is_json {
        error::payload_too_large().into_response()
    } else {
        resp
    }
}

/// How `memex serve --root <dir> --listen <host:port>` was invoked.
pub struct RunOptions {
    pub root: PathBuf,
    pub listen: String,
    pub with_embeddings: bool,
    pub log_level: String,
}

/// Runs the vault server until SIGINT or SIGTERM. Every startup failure is
/// returned before anything listens or is served.
pub async fn run(opts: RunOptions) -> Result<()> {
    run_with_probe(opts, &fs_guard::probe).await
}

/// [`run`] with the network-drive guard on `--root` asking `probe` instead
/// of `statfs`.
pub async fn run_with_probe(
    opts: RunOptions,
    probe: &(dyn Fn(&Path) -> std::io::Result<FsInfo> + Sync),
) -> Result<()> {
    let filter = log::filter(&opts.log_level)?;
    let root = vault_root(&opts.root, probe)?;
    let listener = tokio::net::TcpListener::bind(&opts.listen)
        .await
        .with_context(|| format!("listen on {}", opts.listen))?;
    let addr = listener
        .local_addr()
        .context("read the listening address")?;
    let resolved = token::resolve(&root, std::env::var_os(token::TOKEN_ENV))?;
    let _log_guard = log::init(&root, filter)?;

    if let Some(path) = &resolved.generated {
        eprintln!(
            "memex serve: generated a new access token in {}",
            path.display()
        );
    }
    tracing::info!(
        root = %root.display(),
        %addr,
        version = env!("CARGO_PKG_VERSION"),
        api_version = API_VERSION,
        with_embeddings = opts.with_embeddings,
        utc_offset = %chrono::Local::now().offset(),
        "vault server started"
    );
    eprintln!("memex serve: vault server listening on http://{addr}");

    let config = ServerConfig::new(root, resolved.token).with_embeddings(opts.with_embeddings);
    axum::serve(listener, router(config))
        .with_graceful_shutdown(shutdown_signal())
        .await
        .context("serve")?;
    tracing::info!("vault server stopped");
    Ok(())
}

/// `--root` as an absolute, canonical path to an existing directory on a
/// local filesystem (req 8, 30).
fn vault_root(root: &Path, probe: &dyn Fn(&Path) -> std::io::Result<FsInfo>) -> Result<PathBuf> {
    let shown = root.display();
    match std::fs::metadata(root) {
        Ok(meta) if meta.is_dir() => {
            let canonical =
                std::fs::canonicalize(root).with_context(|| format!("resolve --root {shown}"))?;
            fs_guard::check_with(&canonical, probe)?;
            Ok(canonical)
        }
        Ok(_) => Err(InvalidArgument(format!("--root {shown} is not a directory")).into()),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => {
            Err(InvalidArgument(format!("--root {shown} does not exist")).into())
        }
        Err(e) => Err(e).with_context(|| format!("read --root {shown}")),
    }
}

/// Resolves on SIGINT (Ctrl-C) or SIGTERM.
async fn shutdown_signal() {
    let ctrl_c = async {
        let _ = tokio::signal::ctrl_c().await;
    };
    let term = async {
        match tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate()) {
            Ok(mut sig) => {
                sig.recv().await;
            }
            Err(_) => std::future::pending::<()>().await,
        }
    };
    tokio::select! {
        () = ctrl_c => {}
        () = term => {}
    }
}
