//! Background embedding backfill for `memex serve --with-embeddings`
//! (Spec #391 req 6 and 7, #422).
//!
//! The backfill runs `embed_missing(None, 0, 64)` through a [`VaultLease`]
//! until `pending` is 0. Each batch reads under the vault lock, embeds on a
//! blocking thread with no lock held, takes the lock again for the insert
//! transaction alone, and yields before the next batch.
//!
//! - stdio: [`spawn_stdio`] starts one task for the served vault.
//! - vault server: [`spawn_server`] starts one server-wide task that works
//!   every vault the registry has open, and each vault it opens later,
//!   one batch of 64 at a time, round-robin across vaults.
//!
//! Inference: a batch picks up to 64 chunks but embeds them in calls of
//! at most [`BACKFILL_EMBED_SUB_BATCH`] texts ([`SubBatchEmbedder`]), so a
//! request that embeds on the same embedder waits for at most one short
//! call, not a whole batch's inference (ruling D48).
//!
//! Shutdown: each batch runs on its own plain thread, not the Tokio
//! blocking pool, because runtime shutdown waits for every blocking task
//! that has started. Dropping the backfill task (stdin EOF, server
//! shutdown, or an abort) cancels its batch: the batch takes no further
//! lease, so it writes nothing more, and the process exits without waiting
//! for its inference or model download.

use std::collections::{HashSet, VecDeque};
use std::panic::AssertUnwindSafe;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;

use memex_core::embedder::Embedder;
use memex_core::vectors::{embed_missing, ConnLease, EmbedMissing};
use memex_core::{MemexError, Result, Vault};
use rusqlite::Connection;
use tokio::sync::Mutex;
use tokio::task::JoinHandle;
use ulid::Ulid;

use crate::server::registry::Registry;
use crate::state::AppState;

/// The most chunks one backfill batch embeds.
const BATCH: usize = 64;

/// The most texts one backfill `embed_batch` call gets (ruling D48).
pub const BACKFILL_EMBED_SUB_BATCH: usize = 8;

/// An [`Embedder`] that passes `inner` at most
/// [`BACKFILL_EMBED_SUB_BATCH`] texts per call: a call of `n` texts makes
/// `ceil(n / 8)` calls to `inner`, in order, and returns their vectors
/// concatenated. The first inner error is returned as is.
pub struct SubBatchEmbedder {
    inner: Arc<dyn Embedder>,
}

impl SubBatchEmbedder {
    /// Wraps `inner`.
    pub fn new(inner: Arc<dyn Embedder>) -> Self {
        Self { inner }
    }
}

impl Embedder for SubBatchEmbedder {
    fn model_version(&self) -> &str {
        self.inner.model_version()
    }

    fn dimension(&self) -> usize {
        self.inner.dimension()
    }

    fn embed_batch(&self, texts: &[String]) -> Result<Vec<Vec<f32>>> {
        let mut out = Vec::with_capacity(texts.len());
        for part in texts.chunks(BACKFILL_EMBED_SUB_BATCH) {
            out.extend(self.inner.embed_batch(part)?);
        }
        Ok(out)
    }
}

/// A [`ConnLease`] that locks a served vault (`AppState::vault`) for each
/// lease call and releases it before the call returns, so the lock is never
/// held across inference. Use it on a blocking thread.
pub struct VaultLease {
    vault: Arc<Mutex<Vault>>,
    /// Set once the batch is cancelled: every later lease call fails.
    cancelled: Option<Arc<AtomicBool>>,
}

impl VaultLease {
    /// A lease over `vault` (an `AppState::vault`).
    pub fn new(vault: Arc<Mutex<Vault>>) -> Self {
        Self {
            vault,
            cancelled: None,
        }
    }
}

impl ConnLease for VaultLease {
    fn lease<R>(&mut self, f: impl FnOnce(&mut Connection) -> Result<R>) -> Result<R> {
        let cancelled = || {
            self.cancelled
                .as_ref()
                .is_some_and(|flag| flag.load(Ordering::SeqCst))
        };
        if cancelled() {
            return Err(MemexError::Io(std::io::Error::new(
                std::io::ErrorKind::Interrupted,
                "embedding backfill cancelled",
            )));
        }
        let mut vault = self.vault.blocking_lock();
        f(vault.connection_mut())
    }
}

/// Cancels a batch's lease when dropped, so dropping the task awaiting the
/// batch stops it at its next lease call.
struct CancelOnDrop(Arc<AtomicBool>);

impl Drop for CancelOnDrop {
    fn drop(&mut self) {
        self.0.store(true, Ordering::SeqCst);
    }
}

/// Starts the stdio backfill of `state`'s vault: `None` when `state` has no
/// embedder. The task ends once `pending` is 0, or after logging an
/// embedder error.
pub fn spawn_stdio(state: &AppState) -> Option<JoinHandle<()>> {
    let embedder = state.embedder.clone()?;
    let mut pass = Pass::new(state, embedder);
    Some(tokio::spawn(async move {
        while pass.step().await {
            tokio::task::yield_now().await;
        }
    }))
}

/// Starts the vault server's one backfill task over `registry`: `None` when
/// the registry has no embedder, or when called outside a Tokio runtime.
///
/// The task first works every vault already open, then sleeps until the
/// registry opens another one. It never ends on its own: it is dropped with
/// the runtime, or aborted through the returned handle.
pub fn spawn_server(registry: Arc<Registry>) -> Option<JoinHandle<()>> {
    let embedder = registry.embedder()?;
    let runtime = tokio::runtime::Handle::try_current().ok()?;
    Some(runtime.spawn(serve_passes(registry, embedder)))
}

/// The server task: one batch per turn, round-robin over the vaults whose
/// pass is not done. A vault the registry opens during a batch queues ahead
/// of the vault that batch was for.
async fn serve_passes(registry: Arc<Registry>, embedder: Arc<dyn Embedder>) {
    let mut queue: VecDeque<(Ulid, Pass)> = VecDeque::new();
    // The open vaults (by `open_id`) that have had a pass, or are in one.
    let mut known: HashSet<Ulid> = HashSet::new();
    loop {
        admit(&registry, &embedder, &mut queue, &mut known);
        let Some((open_id, mut pass)) = queue.pop_front() else {
            // An open after the snapshot above leaves a wake-up behind.
            registry.opened().await;
            continue;
        };
        let more = pass.step().await;
        admit(&registry, &embedder, &mut queue, &mut known);
        if more && known.contains(&open_id) {
            queue.push_back((open_id, pass));
        }
        tokio::task::yield_now().await;
    }
}

/// Queues a pass for every vault the registry has open that has not had
/// one, and forgets the vaults it no longer has open.
fn admit(
    registry: &Registry,
    embedder: &Arc<dyn Embedder>,
    queue: &mut VecDeque<(Ulid, Pass)>,
    known: &mut HashSet<Ulid>,
) {
    let open = registry.open_entries();
    let ids: HashSet<Ulid> = open.iter().map(|entry| entry.open_id).collect();
    known.retain(|id| ids.contains(id));
    queue.retain(|(id, _)| ids.contains(id));
    for entry in open {
        if known.insert(entry.open_id) {
            queue.push_back((entry.open_id, Pass::new(&entry.state, embedder.clone())));
        }
    }
}

/// One vault's backfill, a batch at a time.
struct Pass {
    vault: Arc<Mutex<Vault>>,
    path: PathBuf,
    embedder: Arc<dyn Embedder>,
    /// `pending` after the last batch.
    pending: Option<usize>,
}

impl Pass {
    fn new(state: &AppState, embedder: Arc<dyn Embedder>) -> Self {
        Self {
            vault: state.vault.clone(),
            path: state.vault_path.clone(),
            embedder,
            pending: None,
        }
    }

    /// Embeds one batch on its own thread. True while chunks are left and
    /// the batch made progress; an embedder error is logged and ends the
    /// pass. Dropping the returned future cancels the batch (module docs).
    async fn step(&mut self) -> bool {
        let out = match self.run_batch().await {
            Ok(Ok(out)) => out,
            Ok(Err(e)) => {
                tracing::warn!(
                    vault = %self.path.display(),
                    error = %e,
                    "embedding backfill stopped for this vault: a batch failed"
                );
                return false;
            }
            Err(e) => {
                tracing::error!(
                    vault = %self.path.display(),
                    error = %e,
                    "embedding backfill stopped for this vault: a batch did not finish"
                );
                return false;
            }
        };
        // Progress: vectors written, or fewer chunks left (others embedded
        // or deleted the picked chunks meanwhile). Without it the pass stops
        // instead of spinning.
        let progressed = out.embedded > 0 || self.pending.is_none_or(|before| out.pending < before);
        self.pending = Some(out.pending);
        if out.pending > 0 && !progressed {
            tracing::warn!(
                vault = %self.path.display(),
                pending = out.pending,
                "embedding backfill stopped for this vault: a batch made no progress"
            );
        }
        out.pending > 0 && progressed
    }

    /// One `embed_missing` batch on a plain thread. `Err` carries why the
    /// batch did not finish: it panicked, or its thread could not start.
    async fn run_batch(&self) -> std::result::Result<Result<EmbedMissing>, String> {
        let flag = Arc::new(AtomicBool::new(false));
        let _cancel = CancelOnDrop(flag.clone());
        let mut lease = VaultLease {
            vault: self.vault.clone(),
            cancelled: Some(flag),
        };
        let embedder = SubBatchEmbedder::new(self.embedder.clone());
        let (done, result) = tokio::sync::oneshot::channel();
        std::thread::Builder::new()
            .name("memex-backfill".to_string())
            .spawn(move || {
                let run = std::panic::catch_unwind(AssertUnwindSafe(|| {
                    embed_missing(&mut lease, &embedder, None, 0, BATCH)
                }));
                let _ = done.send(run.map_err(|payload| {
                    let message = payload
                        .downcast_ref::<&str>()
                        .map(|s| s.to_string())
                        .or_else(|| payload.downcast_ref::<String>().cloned())
                        .unwrap_or_else(|| "a non-string payload".to_string());
                    format!("the batch panicked: {message}")
                }));
            })
            .map_err(|e| format!("the batch thread did not start: {e}"))?;
        result
            .await
            .map_err(|_| "the batch thread ended without a result".to_string())?
    }
}
