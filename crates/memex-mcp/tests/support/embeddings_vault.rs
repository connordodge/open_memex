//! Temp vaults and model caches for the `memex embeddings status` and
//! `GET /vaults/{name}/api/v1/embeddings` tests (#403, Spec #394 req 43).
//!
//! Include it with `#[path = "support/embeddings_vault.rs"] mod embeddings_vault;`
//! next to `#[path = "../../memex-core/tests/hf_cache_fixture/mod.rs"] mod hf_cache_fixture;`
//! (this file reads the K0 fixture through `crate::hf_cache_fixture`).

#![allow(dead_code)]

use std::fs;
use std::path::{Path, PathBuf};

use memex_core::embedder::{Embedder, FakeEmbedder};
use memex_core::indexer;
use memex_core::notes::{create_note, CreateNote};
use memex_core::Vault;

use crate::hf_cache_fixture as fx;

/// What a built vault holds, counted with raw SQL before it was closed.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Built {
    /// Rows in `chunks` (N).
    pub chunks: i64,
    /// `chunk_vec` rows whose chunk exists (M).
    pub joined: i64,
    /// `chunk_vec` rows whose chunk does not exist (K).
    pub orphans: i64,
    /// Whether `chunk_vec` exists.
    pub has_chunk_vec: bool,
}

/// The vector dimension of the fake embedder the vaults are built with.
pub const DIM: usize = 8;

/// Notes written with the fake embedder (their chunks get vectors).
pub const EMBEDDED_NOTES: [(&str, &str); 3] = [
    (
        "Storage",
        "We chose SQLite because the app is local-first.\n\nThe file sits in the vault folder.",
    ),
    ("Search", "Hybrid search fuses BM25 with cosine similarity."),
    (
        "Echoes",
        "Echoes show passages that mean the same thing.\n\nThey read the embedded chunks.\n\nNothing leaves the machine.",
    ),
];

/// Notes indexed without vectors (their chunks are waiting).
pub const PLAIN_NOTES: [(&str, &str); 2] = [
    ("Lunch", "I had a sandwich. The bread was sourdough."),
    (
        "Errands",
        "Buy stamps.\n\nReturn the library books.\n\nCall the plumber about the tap.",
    ),
];

fn write_notes(vault: &mut Vault, notes: &[(&str, &str)], embedder: Option<&dyn Embedder>) {
    for (title, body) in notes {
        let n = create_note(
            vault,
            CreateNote {
                title: Some(title.to_string()),
                content_md: body.to_string(),
                ..Default::default()
            },
        )
        .unwrap();
        indexer::reindex_note(vault.connection_mut(), n.id.as_str(), body, embedder).unwrap();
    }
}

fn count(vault: &Vault, sql: &str) -> i64 {
    vault
        .connection_ref()
        .query_row(sql, [], |r| r.get(0))
        .unwrap_or_else(|e| panic!("{sql}: {e}"))
}

fn unit_vector_bytes() -> Vec<u8> {
    let mut unit = [0f32; DIM];
    unit[0] = 1.0;
    unit.iter().flat_map(|f| f.to_le_bytes()).collect()
}

/// Creates a vault at `dir` with `embedded` notes written through the fake
/// embedder, `plain` notes without vectors, and `orphans` `chunk_vec` rows
/// whose chunk id is in no `chunks` row. Closes it and returns its counts.
pub fn build_vault(
    dir: &Path,
    embedded: &[(&str, &str)],
    plain: &[(&str, &str)],
    orphans: usize,
) -> Built {
    let mut vault = Vault::create(dir).unwrap_or_else(|e| panic!("create {dir:?}: {e}"));
    let emb = FakeEmbedder::new(DIM);
    write_notes(&mut vault, embedded, Some(&emb));
    write_notes(&mut vault, plain, None);
    let has_chunk_vec = count(
        &vault,
        "SELECT COUNT(*) FROM sqlite_master WHERE name = 'chunk_vec'",
    ) > 0;
    assert!(
        has_chunk_vec || orphans == 0,
        "fixture: orphans need chunk_vec (write at least one embedded note)"
    );
    for i in 0..orphans {
        let id = format!("01ORPHANCHUNK{i:013}");
        vault
            .connection_ref()
            .execute(
                "INSERT INTO chunk_vec (chunk_id, embedding) VALUES (?, ?)",
                rusqlite::params![id, unit_vector_bytes()],
            )
            .unwrap();
    }
    let chunks = count(&vault, "SELECT COUNT(*) FROM chunks");
    let (joined, total) = if has_chunk_vec {
        (
            count(
                &vault,
                "SELECT COUNT(*) FROM chunk_vec v JOIN chunks c ON c.id = v.chunk_id",
            ),
            count(&vault, "SELECT COUNT(*) FROM chunk_vec"),
        )
    } else {
        (0, 0)
    };
    drop(vault);
    Built {
        chunks,
        joined,
        orphans: total - joined,
        has_chunk_vec,
    }
}

/// The standard vault for the counts tests: N chunks, M joined vectors and
/// K orphans, with N, M, K, M + K and N - M all different, so no swapped or
/// summed field can match by accident.
pub fn build_counted_vault(dir: &Path) -> Built {
    let built = build_vault(dir, &EMBEDDED_NOTES, &PLAIN_NOTES, 4);
    let Built {
        chunks: n,
        joined: m,
        orphans: k,
        has_chunk_vec,
    } = built;
    assert!(has_chunk_vec, "fixture: chunk_vec exists");
    assert_eq!(k, 4, "fixture: four orphans");
    assert!(0 < m && m < n, "fixture: some chunks waiting ({m}/{n})");
    let distinct: std::collections::BTreeSet<i64> = [n, m, k, m + k, n - m].into();
    assert_eq!(distinct.len(), 5, "fixture: N={n} M={m} K={k} all distinct");
    built
}

/// A vault without `chunk_vec`: notes indexed FTS-only.
pub fn build_vault_without_chunk_vec(dir: &Path) -> Built {
    let built = build_vault(dir, &[], &PLAIN_NOTES, 0);
    assert!(!built.has_chunk_vec, "fixture: no chunk_vec");
    assert!(
        built.chunks >= 2,
        "fixture: chunks exist ({})",
        built.chunks
    );
    built
}

// ---------------------------------------------------------------------------
// Model cache sizes (lead ruling: regular-file lengths, symlinks not followed)
// ---------------------------------------------------------------------------

fn len(p: &Path) -> u64 {
    fs::symlink_metadata(p)
        .unwrap_or_else(|e| panic!("{p:?}: {e}"))
        .len()
}

/// `refs/main` of the fixture repo.
pub fn ref_file(cache_dir: &Path) -> PathBuf {
    fx::repo_dir(cache_dir).join("refs").join("main")
}

/// The on-disk size of a [`fx::write_complete_linked`] cache: every blob
/// once plus `refs/main`. The snapshot pointers are symlinks and add nothing.
pub fn linked_cache_bytes(cache_dir: &Path) -> u64 {
    let blobs: u64 = fx::required_files()
        .iter()
        .map(|f| len(&fx::blob_path(cache_dir, &fx::etag_for(f))))
        .sum();
    blobs + len(&ref_file(cache_dir))
}

/// The on-disk size of a [`fx::write_complete`] cache: every snapshot file
/// (plain files there) plus `refs/main`.
pub fn plain_cache_bytes(cache_dir: &Path) -> u64 {
    let files: u64 = fx::required_files()
        .iter()
        .map(|f| len(&fx::snapshot_file(cache_dir, f)))
        .sum();
    files + len(&ref_file(cache_dir))
}

/// What a walk that FOLLOWS the snapshot symlinks would report for a linked
/// cache: every blob twice. A correct size is never this.
pub fn linked_cache_bytes_if_links_followed(cache_dir: &Path) -> u64 {
    let blobs = linked_cache_bytes(cache_dir) - len(&ref_file(cache_dir));
    2 * blobs + len(&ref_file(cache_dir))
}
