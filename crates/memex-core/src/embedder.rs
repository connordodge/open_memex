//! Pluggable text embedder. The trait keeps the indexer/search code free of
//! a hard dependency on any particular ML runtime; tests use [`FakeEmbedder`]
//! and the real app uses [`FastEmbedder`] (lazy-loaded BGE-small).

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Condvar, Mutex};

use crate::error::MemexError;
use crate::Result;

pub trait Embedder: Send + Sync {
    fn model_version(&self) -> &str;
    fn dimension(&self) -> usize;
    fn embed_batch(&self, texts: &[String]) -> Result<Vec<Vec<f32>>>;
}

/// Deterministic fake embedder for tests. Hashes each input into a small
/// vector so that tests can assert on relative ordering without depending
/// on a real model download.
pub struct FakeEmbedder {
    pub dim: usize,
}

impl FakeEmbedder {
    pub fn new(dim: usize) -> Self {
        Self { dim }
    }
}

impl Embedder for FakeEmbedder {
    fn model_version(&self) -> &str {
        "fake-v1"
    }

    fn dimension(&self) -> usize {
        self.dim
    }

    fn embed_batch(&self, texts: &[String]) -> Result<Vec<Vec<f32>>> {
        let mut out = Vec::with_capacity(texts.len());
        for t in texts {
            out.push(hash_to_unit_vec(t, self.dim));
        }
        Ok(out)
    }
}

/// Test double with an exact text-to-vector table, so a test can set
/// similarities precisely. A text with no entry is an `EmbedderInfer` error.
/// Counts `embed_batch` calls (one per batch, whatever its size).
pub struct TableEmbedder {
    dim: usize,
    table: HashMap<String, Vec<f32>>,
    calls: AtomicUsize,
}

impl TableEmbedder {
    pub fn new(dim: usize) -> Self {
        Self {
            dim,
            table: HashMap::new(),
            calls: AtomicUsize::new(0),
        }
    }

    /// Adds (or replaces) the vector for `text`.
    pub fn with(mut self, text: impl Into<String>, vector: Vec<f32>) -> Self {
        self.insert(text, vector);
        self
    }

    /// Adds (or replaces) the vector for `text`.
    pub fn insert(&mut self, text: impl Into<String>, vector: Vec<f32>) {
        self.table.insert(text.into(), vector);
    }

    /// How many times `embed_batch` has been called.
    pub fn calls(&self) -> usize {
        self.calls.load(Ordering::SeqCst)
    }
}

impl Embedder for TableEmbedder {
    fn model_version(&self) -> &str {
        "table-v1"
    }

    fn dimension(&self) -> usize {
        self.dim
    }

    fn embed_batch(&self, texts: &[String]) -> Result<Vec<Vec<f32>>> {
        self.calls.fetch_add(1, Ordering::SeqCst);
        texts
            .iter()
            .map(|t| {
                self.table.get(t).cloned().ok_or_else(|| {
                    MemexError::EmbedderInfer(format!("TableEmbedder has no vector for {t:?}"))
                })
            })
            .collect()
    }
}

/// Test double that blocks inside `embed_batch` until [`GatedEmbedder::release`]
/// opens the gate, then answers with `inner`. The gate stays open once
/// released. Counts `embed_batch` calls.
pub struct GatedEmbedder {
    inner: Box<dyn Embedder>,
    gate: Mutex<Gate>,
    changed: Condvar,
    calls: AtomicUsize,
}

struct Gate {
    open: bool,
    held: usize,
}

impl GatedEmbedder {
    /// A closed gate in front of `inner`.
    pub fn new(inner: impl Embedder + 'static) -> Self {
        Self {
            inner: Box::new(inner),
            gate: Mutex::new(Gate {
                open: false,
                held: 0,
            }),
            changed: Condvar::new(),
            calls: AtomicUsize::new(0),
        }
    }

    /// Blocks until a call is held inside `embed_batch` (true), or until the
    /// gate is opened with no call held (false). Never waits on a clock.
    pub fn wait_entered(&self) -> bool {
        let mut gate = self.gate.lock().unwrap();
        loop {
            if gate.held > 0 {
                return true;
            }
            if gate.open {
                return false;
            }
            gate = self.changed.wait(gate).unwrap();
        }
    }

    /// Opens the gate for every held and future call.
    pub fn release(&self) {
        self.gate.lock().unwrap().open = true;
        self.changed.notify_all();
    }

    /// How many times `embed_batch` has been called.
    pub fn calls(&self) -> usize {
        self.calls.load(Ordering::SeqCst)
    }
}

impl Embedder for GatedEmbedder {
    fn model_version(&self) -> &str {
        self.inner.model_version()
    }

    fn dimension(&self) -> usize {
        self.inner.dimension()
    }

    fn embed_batch(&self, texts: &[String]) -> Result<Vec<Vec<f32>>> {
        self.calls.fetch_add(1, Ordering::SeqCst);
        {
            let mut gate = self.gate.lock().unwrap();
            gate.held += 1;
            self.changed.notify_all();
            while !gate.open {
                gate = self.changed.wait(gate).unwrap();
            }
            gate.held -= 1;
        }
        self.inner.embed_batch(texts)
    }
}

fn hash_to_unit_vec(s: &str, dim: usize) -> Vec<f32> {
    use std::hash::{Hash, Hasher};
    let mut v = vec![0f32; dim];
    for (i, word) in s.split_whitespace().enumerate() {
        let mut h = std::collections::hash_map::DefaultHasher::new();
        word.to_lowercase().hash(&mut h);
        let bucket = (h.finish() as usize) % dim;
        v[bucket] += 1.0;
        // tiny positional signal so chunks of the same words but different
        // orders still differ.
        let pos_bucket = ((h.finish() ^ (i as u64).wrapping_mul(0x9E3779B97F4A7C15)) as usize) % dim;
        v[pos_bucket] += 0.25;
    }
    let norm: f32 = v.iter().map(|x| x * x).sum::<f32>().sqrt().max(1e-6);
    for x in &mut v {
        *x /= norm;
    }
    v
}

/// The tokenizer files fastembed's `load_tokenizer_hf_hub` fetches from the
/// model repo on every text-model load (fastembed 5.13 `common.rs`). fastembed
/// has no public list of them, so they are named here.
const TOKENIZER_FILES: [&str; 4] = [
    "tokenizer.json",
    "config.json",
    "special_tokens_map.json",
    "tokenizer_config.json",
];

/// fastembed-rs backed embedder. The model is loaded lazily on first call so
/// that simply opening a vault does not pay the cost.
pub struct FastEmbedder {
    inner: Mutex<Option<fastembed::TextEmbedding>>,
    cache_dir: Option<PathBuf>,
    model_version: String,
    dimension: usize,
}

impl FastEmbedder {
    pub fn bge_small_en_v15(cache_dir: Option<PathBuf>) -> Self {
        Self {
            inner: Mutex::new(None),
            cache_dir,
            model_version: "BAAI/bge-small-en-v1.5".to_string(),
            dimension: 384,
        }
    }

    /// Whether the complete BGE-small-en-v1.5 model is already in the cache
    /// fastembed will load from when given `cache_dir`, in the layout
    /// fastembed downloads into. It never loads the model, never downloads
    /// and never touches the network.
    ///
    /// Every file fastembed reads on load must resolve through hf-hub's
    /// offline cache lookup (`refs/main` -> `snapshots/<commit>/<file>`,
    /// following blob symlinks) to a regular file: the model info's
    /// `model_file` and `additional_files`, plus the tokenizer files. An
    /// unfinished download has no snapshot pointer yet, so it reads false.
    ///
    /// The directory checked is `$HF_HOME` when that is set, else
    /// `cache_dir`, because that is where fastembed's loader looks (see
    /// `load_cache_dir`). So true means loading needs no download.
    pub fn is_cached(cache_dir: &Path) -> bool {
        let Ok(info) =
            fastembed::TextEmbedding::get_model_info(&fastembed::EmbeddingModel::BGESmallENV15)
        else {
            return false;
        };
        let repo =
            hf_hub::Cache::new(Self::load_cache_dir(cache_dir)).model(info.model_code.clone());
        std::iter::once(info.model_file.as_str())
            .chain(info.additional_files.iter().map(String::as_str))
            .chain(TOKENIZER_FILES)
            .all(|file| repo.get(file).is_some_and(|p| p.is_file()))
    }

    /// The model cache directory fastembed reads and downloads into when it
    /// is given `cache_dir`. fastembed 5's `pull_from_hf` replaces the dir
    /// with `$HF_HOME` whenever `env::var("HF_HOME")` succeeds, so a
    /// non-UTF-8 value falls back to `cache_dir` here too. `is_cached` and
    /// `ensure_loaded` both resolve through this, so the cache check and the
    /// load cannot look in different places.
    pub fn load_cache_dir(cache_dir: &Path) -> PathBuf {
        std::env::var("HF_HOME")
            .map(PathBuf::from)
            .unwrap_or_else(|_| cache_dir.to_path_buf())
    }

    fn ensure_loaded(&self) -> Result<()> {
        let mut guard = self.inner.lock().unwrap();
        if guard.is_some() {
            return Ok(());
        }
        let mut opts =
            fastembed::InitOptions::new(fastembed::EmbeddingModel::BGESmallENV15)
                .with_show_download_progress(false);
        if let Some(dir) = &self.cache_dir {
            opts = opts.with_cache_dir(Self::load_cache_dir(dir));
        }
        let model = fastembed::TextEmbedding::try_new(opts)
            .map_err(|e| MemexError::EmbedderInit(e.to_string()))?;
        *guard = Some(model);
        Ok(())
    }
}

impl Embedder for FastEmbedder {
    fn model_version(&self) -> &str {
        &self.model_version
    }

    fn dimension(&self) -> usize {
        self.dimension
    }

    fn embed_batch(&self, texts: &[String]) -> Result<Vec<Vec<f32>>> {
        if texts.is_empty() {
            return Ok(Vec::new());
        }
        self.ensure_loaded()?;
        let mut guard = self.inner.lock().unwrap();
        let model = guard.as_mut().expect("loaded");
        let docs: Vec<&str> = texts.iter().map(|s| s.as_str()).collect();
        let vecs = model
            .embed(docs, None)
            .map_err(|e| MemexError::EmbedderInfer(e.to_string()))?;
        // Sanity check dimension on first batch.
        if let Some(first) = vecs.first() {
            if first.len() != self.dimension {
                return Err(MemexError::EmbedderInfer(format!(
                    "embedder returned dim {}; expected {}",
                    first.len(),
                    self.dimension
                )));
            }
        }
        Ok(vecs)
    }
}
