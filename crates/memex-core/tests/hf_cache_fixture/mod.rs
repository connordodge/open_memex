//! Fake BGE-small-en-v1.5 model caches in the layout fastembed downloads
//! into (hf-hub 0.5's cache, `fastembed::pull_from_hf`), for the
//! `FastEmbedder::is_cached` tests (#417).
//!
//! Layout, from hf-hub's `CacheRepo` and `ApiRepo::download_with_progress`:
//!
//! ```text
//! <cache_dir>/models--<org>--<name>/
//!   refs/main                    commit hash (no newline), written after each file
//!   snapshots/<commit>/<file>    one pointer per file (symlink to ../blobs/<etag>)
//!   blobs/<etag>                 finished file
//!   blobs/<etag>.part            download in progress (renamed to <etag> when done)
//!   blobs/<etag>.lock            download lock
//! ```
//!
//! The file list comes from fastembed itself: the model info's `model_file`
//! and `additional_files`, plus the four tokenizer files
//! `load_tokenizer_hf_hub` reads from the same repo on every load
//! (fastembed 5.13 `common.rs:37-44`). Every one of them must be present,
//! or `TextEmbedding::try_new` downloads it.

#![allow(dead_code)]

use std::fs;
use std::path::{Path, PathBuf};

/// The tokenizer files `fastembed::common::load_tokenizer_hf_hub` fetches
/// with `model_repo.get(..)` for every text model. fastembed has no public
/// list of them, so they are named here once.
pub const TOKENIZER_FILES: [&str; 4] = [
    "tokenizer.json",
    "config.json",
    "special_tokens_map.json",
    "tokenizer_config.json",
];

/// A fake commit hash for the snapshot the fixtures write.
pub const COMMIT: &str = "5c38ec7c405ec4b44b94cc5a9bb96e735b38267a";

fn info() -> &'static fastembed::ModelInfo<fastembed::EmbeddingModel> {
    fastembed::TextEmbedding::get_model_info(&fastembed::EmbeddingModel::BGESmallENV15)
        .expect("fastembed knows BGE-small-en-v1.5")
}

/// The Hugging Face repo id fastembed pulls BGE-small-en-v1.5 from.
pub fn model_code() -> String {
    info().model_code.clone()
}

/// Every file `TextEmbedding::try_new` reads from the repo for
/// BGE-small-en-v1.5, model file first.
pub fn required_files() -> Vec<String> {
    let info = info();
    let mut files = vec![info.model_file.clone()];
    files.extend(info.additional_files.iter().cloned());
    files.extend(TOKENIZER_FILES.iter().map(|f| f.to_string()));
    files
}

/// `<cache_dir>/models--<org>--<name>`, hf-hub's `Repo::folder_name`.
pub fn repo_dir(cache_dir: &Path) -> PathBuf {
    cache_dir.join(format!("models--{}", model_code()).replace('/', "--"))
}

pub fn snapshot_dir(cache_dir: &Path, commit: &str) -> PathBuf {
    repo_dir(cache_dir).join("snapshots").join(commit)
}

/// The snapshot pointer for `file` under [`COMMIT`].
pub fn snapshot_file(cache_dir: &Path, file: &str) -> PathBuf {
    snapshot_dir(cache_dir, COMMIT).join(file)
}

pub fn blob_path(cache_dir: &Path, etag: &str) -> PathBuf {
    repo_dir(cache_dir).join("blobs").join(etag)
}

/// A distinct fake etag per file.
pub fn etag_for(file: &str) -> String {
    let mut h: u64 = 0xcbf29ce484222325;
    for b in file.bytes() {
        h ^= b as u64;
        h = h.wrapping_mul(0x100000001b3);
    }
    format!("{h:016x}{:024x}", file.len())
}

/// Points `refs/main` at `commit`, the way hf-hub's `create_ref` does.
pub fn write_ref(cache_dir: &Path, commit: &str) {
    let refs = repo_dir(cache_dir).join("refs");
    fs::create_dir_all(&refs).unwrap();
    fs::write(refs.join("main"), commit).unwrap();
}

fn write_fake(path: &Path, file: &str) {
    fs::create_dir_all(path.parent().unwrap()).unwrap();
    // Small and not a real model: loading it would fail.
    fs::write(path, format!("fake {file}\n")).unwrap();
}

/// Writes `files` as plain files in the snapshot for `commit`.
pub fn write_snapshot_files(cache_dir: &Path, commit: &str, files: &[String]) {
    for f in files {
        write_fake(&snapshot_dir(cache_dir, commit).join(f), f);
    }
}

/// A complete cache: `refs/main` -> [`COMMIT`], every required file present
/// as a small plain file in that snapshot.
pub fn write_complete(cache_dir: &Path) {
    write_snapshot_files(cache_dir, COMMIT, &required_files());
    write_ref(cache_dir, COMMIT);
}

/// Finishes one file the way hf-hub does: blob, then a relative symlink
/// pointer in the snapshot.
#[cfg(unix)]
pub fn write_linked_file(cache_dir: &Path, file: &str) {
    let blob = blob_path(cache_dir, &etag_for(file));
    write_fake(&blob, file);
    let pointer = snapshot_file(cache_dir, file);
    fs::create_dir_all(pointer.parent().unwrap()).unwrap();
    let depth = Path::new(file).components().count();
    let mut target = PathBuf::new();
    // snapshots/<commit>/<file...> -> ../../(..)*blobs/<etag>
    for _ in 0..(depth + 1) {
        target.push("..");
    }
    target.push("blobs");
    target.push(etag_for(file));
    std::os::unix::fs::symlink(&target, &pointer).unwrap();
    assert!(
        pointer.exists(),
        "symlink {pointer:?} -> {target:?} resolves"
    );
}

/// A complete cache exactly as hf-hub writes it: blobs plus symlinks.
#[cfg(unix)]
pub fn write_complete_linked(cache_dir: &Path) {
    for f in required_files() {
        write_linked_file(cache_dir, &f);
    }
    write_ref(cache_dir, COMMIT);
}

/// Every file under `dir`, relative, sorted (for "nothing was written" checks).
pub fn tree(dir: &Path) -> Vec<PathBuf> {
    fn walk(base: &Path, dir: &Path, out: &mut Vec<PathBuf>) {
        let Ok(rd) = fs::read_dir(dir) else { return };
        for e in rd.flatten() {
            let p = e.path();
            out.push(p.strip_prefix(base).unwrap().to_path_buf());
            if e.file_type().map(|t| t.is_dir()).unwrap_or(false) {
                walk(base, &p, out);
            }
        }
    }
    let mut out = Vec::new();
    walk(dir, dir, &mut out);
    out.sort();
    out
}

/// A local TCP port that counts and drops every connection, for
/// `HF_ENDPOINT`. Any hf-hub request fails at once and is counted.
pub struct Tripwire {
    pub url: String,
    hits: std::sync::Arc<std::sync::atomic::AtomicUsize>,
}

impl Tripwire {
    pub fn start() -> Self {
        use std::sync::atomic::{AtomicUsize, Ordering};
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let url = format!("http://{}", listener.local_addr().unwrap());
        let hits = std::sync::Arc::new(AtomicUsize::new(0));
        let h = hits.clone();
        std::thread::spawn(move || {
            for s in listener.incoming() {
                h.fetch_add(1, Ordering::SeqCst);
                drop(s);
            }
        });
        Self { url, hits }
    }

    pub fn hits(&self) -> usize {
        self.hits.load(std::sync::atomic::Ordering::SeqCst)
    }
}

/// A 63-byte ONNX graph (one `Identity` node, ir 8, opset 13) that onnxruntime
/// loads. With it as the model file, `TextEmbedding::try_new` gets past
/// `commit_from_file` and on to the tokenizer files, which the fake model
/// bytes never allow.
pub const MINIMAL_ONNX: [u8; 63] = [
    0x08, 0x08, 0x42, 0x02, 0x10, 0x0d, 0x3a, 0x37, 0x0a, 0x10, 0x0a, 0x01, 0x78, 0x12, 0x01, 0x79,
    0x22, 0x08, 0x49, 0x64, 0x65, 0x6e, 0x74, 0x69, 0x74, 0x79, 0x12, 0x01, 0x67, 0x5a, 0x0f, 0x0a,
    0x01, 0x78, 0x12, 0x0a, 0x0a, 0x08, 0x08, 0x01, 0x12, 0x04, 0x0a, 0x02, 0x08, 0x01, 0x62, 0x0f,
    0x0a, 0x01, 0x79, 0x12, 0x0a, 0x0a, 0x08, 0x08, 0x01, 0x12, 0x04, 0x0a, 0x02, 0x08, 0x01,
];

/// [`write_complete`], with the model file replaced by [`MINIMAL_ONNX`].
pub fn write_complete_loadable(cache_dir: &Path) {
    write_complete(cache_dir);
    fs::write(snapshot_file(cache_dir, &required_files()[0]), MINIMAL_ONNX).unwrap();
}
