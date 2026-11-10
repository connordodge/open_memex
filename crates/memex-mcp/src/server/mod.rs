//! The vault server: `memex serve --root <dir> --listen <host:port>`.
//!
//! One axum router serves every route under one bearer-token layer (D7).
//! From the outside in, a request passes the access log, the auth layer and
//! the 8 MiB body limit before it reaches a route. On a `/vaults/{name}/…`
//! path the vault guard then resolves the vault (or answers 404
//! `vault_not_found`) before any handler runs.

use std::path::{Path, PathBuf};
use std::sync::Arc;

use anyhow::{Context, Result};
use axum::extract::DefaultBodyLimit;
use axum::http::header::CONTENT_TYPE;
use axum::http::StatusCode;
use axum::middleware::{from_fn, from_fn_with_state, map_response};
use axum::response::{IntoResponse, Response};
use axum::routing::get;
use axum::{Extension, Json, Router};
use memex_core::embedder::Embedder;
use memex_core::fs_guard::{self, FsInfo};
use memex_core::{MemexError, SystemClock};
use serde_json::{json, Value};
use tower_http::limit::RequestBodyLimitLayer;

use crate::cli::InvalidArgument;

pub mod api;
pub mod auth;
pub mod backup;
pub mod bridge;
pub mod error;
pub mod log;
pub mod mcp;
pub mod registry;
pub mod request_clock;
pub mod token;
pub mod vaults;

use backup::{BackupArchiveHook, BackupConfig, BackupService};
use error::ApiError;
use registry::Registry;
use request_clock::{BaseClock, SharedClock};

/// The app API version this server speaks (the app's `kApiVersion`, D17).
pub const API_VERSION: u32 = 1;

/// The largest request body the server reads (req 19): 8 MiB.
pub const BODY_LIMIT: usize = 8 * 1024 * 1024;

/// How often the vault server checks which vaults are due a backup (req 28).
const BACKUP_CHECK_EVERY: std::time::Duration = std::time::Duration::from_secs(60 * 60);

/// What the vault server needs to build its router. The token is already
/// resolved and trimmed; `router()` never reads the environment.
#[derive(Clone)]
pub struct ServerConfig {
    root: PathBuf,
    token: String,
    with_embeddings: bool,
    embedder: Option<Arc<dyn Embedder>>,
    clock: SharedClock,
    backups: Option<BackupConfig>,
    backup_archive_hook: Option<BackupArchiveHook>,
}

impl ServerConfig {
    /// A config serving the vault root `root`, accepting only `token`.
    pub fn new(root: impl Into<PathBuf>, token: impl Into<String>) -> Self {
        Self {
            root: root.into(),
            token: token.into(),
            with_embeddings: false,
            embedder: None,
            clock: Arc::new(SystemClock),
            backups: None,
            backup_archive_hook: None,
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

    /// The embedder every served vault shares (`run` passes the one it
    /// warmed). Without one, `router()` builds one with
    /// `build_embedder_in(root)` when embeddings are on.
    pub fn with_embedder(mut self, embedder: Arc<dyn Embedder>) -> Self {
        self.embedder = Some(embedder);
        self
    }

    /// The server's base clock, under every request's `RequestClock`
    /// (default: `SystemClock`).
    pub fn with_clock(mut self, clock: SharedClock) -> Self {
        self.clock = clock;
        self
    }

    /// The server's base clock.
    pub fn clock(&self) -> SharedClock {
        self.clock.clone()
    }

    /// Turns on backups of every served vault (`--backup-dir`, D15).
    pub fn with_backups(mut self, backups: BackupConfig) -> Self {
        self.backups = Some(backups);
        self
    }

    /// Wraps each backup's `.partial` file in `hook` (tests hold a backup
    /// mid-run with it).
    #[doc(hidden)]
    pub fn with_backup_archive_hook<F>(mut self, hook: F) -> Self
    where
        F: Fn(&Path, std::fs::File) -> std::io::Result<Box<dyn memex_core::backup::ArchiveSink>>
            + Send
            + Sync
            + 'static,
    {
        self.backup_archive_hook = Some(Arc::new(hook));
        self
    }
}

/// The whole vault server: every route, then the auth layer, the body limit
/// and the access log (D7).
pub fn router(config: ServerConfig) -> Router {
    app(config).0
}

/// [`router`], plus the server's [`BackupService`] (D15).
///
/// The service never starts the hourly schedule itself: [`run`] does, and
/// only with `--backup-dir`.
pub fn app(config: ServerConfig) -> (Router, Arc<BackupService>) {
    let embedder = match (&config.embedder, config.with_embeddings) {
        (Some(embedder), _) => Some(embedder.clone()),
        (None, true) => Some(crate::state::build_embedder_in(&config.root)),
        (None, false) => None,
    };
    let registry = Arc::new(Registry::new(config.root.clone(), embedder));
    let service = Arc::new(BackupService::new(
        config.backups.clone(),
        config.backup_archive_hook.clone(),
        registry.clone(),
        config.clock(),
    ));
    (routes(&config, registry, service.clone()), service)
}

fn routes(config: &ServerConfig, registry: Arc<Registry>, service: Arc<BackupService>) -> Router {
    let token = auth::AccessToken::new(&config.token);
    Router::new()
        .route("/api/v1/info", get(info))
        .route("/api/v1/vaults", get(vaults::list).post(vaults::create))
        .route("/vaults/{name}/api/v1/info", get(vaults::info))
        .nest("/vaults/{name}/api/v1", api::router())
        .nest("/vaults/{name}/mcp", mcp::router())
        .fallback(not_found)
        // Every route, nest, merge and fallback goes above this line: axum
        // applies `method_not_allowed_fallback` only to the routes already
        // registered, so it must stay the last call before the layers. The
        // layers below wrap everything above them; they are listed inside
        // out.
        .method_not_allowed_fallback(method_not_allowed)
        .layer(from_fn_with_state(registry.clone(), vaults::vault_guard))
        .layer(Extension(registry))
        .layer(Extension(service))
        .layer(Extension(BaseClock(config.clock())))
        .layer(from_fn(request_clock::caller_utc_offset))
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
    /// `--backup-dir` and `--backup-keep`, when given.
    pub backup: Option<BackupConfig>,
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
    let backups = match opts.backup {
        Some(b) => Some(BackupConfig {
            dir: backup::check_dir(&b.dir, &root)?,
            keep: b.keep,
        }),
        None => None,
    };
    let embedder = if opts.with_embeddings {
        Some(warm_embedder(&root).await?)
    } else {
        None
    };
    let listener = tokio::net::TcpListener::bind(&opts.listen)
        .await
        .with_context(|| format!("listen on {}", opts.listen))?;
    let addr = listener
        .local_addr()
        .context("read the listening address")?;
    let env_token = std::env::var_os(token::TOKEN_ENV);
    let from_file = env_token.is_none();
    let resolved = token::resolve(&root, env_token)?;
    let _log_guard = log::init(&root, filter)?;

    if from_file && resolved.generated.is_none() {
        let path = token::token_path(&root);
        if let Some(mode) = token::readable_by_others(&path) {
            tracing::warn!(
                path = %path.display(),
                mode = %format!("{mode:04o}"),
                "the access token file is readable by group or others; chmod 600 it"
            );
        }
    }

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

    let mut config = ServerConfig::new(root, resolved.token).with_embeddings(opts.with_embeddings);
    if let Some(embedder) = embedder {
        config = config.with_embedder(embedder);
    }
    let scheduled = backups.is_some();
    if let Some(backups) = backups {
        tracing::info!(
            backup_dir = %backups.dir.display(),
            keep = backups.keep,
            "backups on"
        );
        config = config.with_backups(backups);
    }
    let (router, service) = app(config);
    if scheduled {
        // The hourly due check (D16). The task is dropped at shutdown, and a
        // running backup's thread is never waited for (req 29).
        spawn_backup_checks(service);
    }
    axum::serve(listener, router)
        .with_graceful_shutdown(shutdown_signal())
        .await
        .context("serve")?;
    tracing::info!("vault server stopped");
    Ok(())
}

/// Starts the due check of every served vault: now, and then one
/// [`BACKUP_CHECK_EVERY`] after each check starts, never sooner and never in
/// a burst after a check that overran (D16, req 29). The task ends when the
/// returned handle is aborted or the runtime is dropped.
#[doc(hidden)]
pub fn spawn_backup_checks(service: Arc<BackupService>) -> tokio::task::JoinHandle<()> {
    tokio::spawn(async move {
        let mut every_hour = tokio::time::interval(BACKUP_CHECK_EVERY);
        every_hour.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
        loop {
            every_hour.tick().await;
            service.run_due_checks().await;
        }
    })
}

/// The embedder every served vault shares, loaded (downloading the model
/// into `<root>/.memex/models` if needed) before the server binds.
async fn warm_embedder(root: &Path) -> Result<Arc<dyn Embedder>> {
    let embedder = crate::state::build_embedder_in(root);
    let warming = embedder.clone();
    tokio::task::spawn_blocking(move || warming.embed_batch(&["warm up".to_string()]))
        .await
        .context("load the embedding model")?
        .context("load the embedding model")?;
    Ok(embedder)
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

#[cfg(test)]
mod tests {
    use super::BACKUP_CHECK_EVERY;

    #[test]
    fn the_backup_due_check_runs_every_hour() {
        assert_eq!(BACKUP_CHECK_EVERY.as_secs(), 3600);
    }
}
