//! Pluggable text embedder. The trait keeps the indexer/search code free of
//! a hard dependency on any particular ML runtime; tests use [`FakeEmbedder`]
//! and the real app uses [`FastEmbedder`] (lazy-loaded BGE-small).

use std::path::PathBuf;
use std::sync::Mutex;

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

    fn ensure_loaded(&self) -> Result<()> {
        let mut guard = self.inner.lock().unwrap();
        if guard.is_some() {
            return Ok(());
        }
        let mut opts =
            fastembed::InitOptions::new(fastembed::EmbeddingModel::BGESmallENV15)
                .with_show_download_progress(false);
        if let Some(dir) = &self.cache_dir {
            opts = opts.with_cache_dir(dir.clone());
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
