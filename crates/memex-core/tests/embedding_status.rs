//! #417 (Spec #391, ruling D6): the embedding status helpers.
//!
//! - AC 1-4: `FastEmbedder::is_cached(cache_dir)` reads fastembed's cache
//!   layout for BGE-small-en-v1.5 (fixtures in `hf_cache_fixture`).
//! - AC 6-7: `vectors::embedding_counts(conn)`.
//!
//! AC 5 (`model_cache_dir`) is in `crates/memex-mcp/tests/model_cache_dir.rs`.

mod hf_cache_fixture;

use std::fs;
use std::path::Path;
use std::sync::OnceLock;
use std::time::Duration;

use hf_cache_fixture as fx;
use memex_core::embedder::{Embedder, FakeEmbedder, FastEmbedder};
use memex_core::indexer;
use memex_core::notes::{create_note, CreateNote};
use memex_core::vectors::{embedding_counts, EmbeddingCounts};
use memex_core::Vault;

/// One tripwire per test binary, with `HF_ENDPOINT` pointed at it before any
/// test calls `is_cached`, so no test here can reach huggingface.co.
fn tripwire() -> &'static fx::Tripwire {
    static T: OnceLock<fx::Tripwire> = OnceLock::new();
    T.get_or_init(|| {
        let t = fx::Tripwire::start();
        std::env::set_var("HF_ENDPOINT", &t.url);
        // fastembed's pull_from_hf prefers HF_HOME over the cache dir it is
        // given; a developer's HF_HOME must not leak into these fixtures.
        std::env::remove_var("HF_HOME");
        t
    })
}

fn is_cached(dir: &Path) -> bool {
    tripwire();
    FastEmbedder::is_cached(dir)
}

// ---------------------------------------------------------------- AC 1

#[test]
fn is_cached_false_for_missing_and_empty_dir() {
    let tmp = tempfile::tempdir().unwrap();

    let missing = tmp.path().join("no-such-models-dir");
    assert!(!is_cached(&missing), "a missing dir is not a cache");
    assert!(!missing.exists(), "is_cached never creates the dir");

    let empty = tmp.path().join("empty");
    fs::create_dir(&empty).unwrap();
    assert!(!is_cached(&empty), "an empty dir is not a cache");
    assert!(fx::tree(&empty).is_empty(), "is_cached writes nothing");

    let not_a_dir = tmp.path().join("models-file");
    fs::write(&not_a_dir, "x").unwrap();
    assert!(!is_cached(&not_a_dir), "a plain file is not a cache");

    // Control: the same empty dir reads true once it holds the model.
    fx::write_complete(&empty);
    assert!(
        is_cached(&empty),
        "the empty dir, once filled with the complete file set, reads true"
    );
}

// ---------------------------------------------------------------- AC 2

#[test]
fn is_cached_true_for_complete_model_file_set() {
    let tmp = tempfile::tempdir().unwrap();
    let files = fx::required_files();
    assert!(
        files.iter().any(|f| f.ends_with(".onnx")),
        "fastembed's model info names an onnx model file: {files:?}"
    );
    fx::write_complete(tmp.path());
    let before = fx::tree(tmp.path());

    assert!(
        is_cached(tmp.path()),
        "complete file set {files:?} in {:?} reads cached",
        fx::repo_dir(tmp.path())
    );
    // The fake files are not a loadable model, so a true here also shows
    // is_cached never loaded it; and it left the cache as it was.
    assert_eq!(fx::tree(tmp.path()), before, "is_cached writes nothing");
}

#[cfg(unix)]
#[test]
fn is_cached_true_for_complete_cache_as_hf_hub_writes_it() {
    let tmp = tempfile::tempdir().unwrap();
    fx::write_complete_linked(tmp.path());
    assert!(
        is_cached(tmp.path()),
        "blobs plus snapshot symlinks (hf-hub's own layout) read cached"
    );
}

// ---------------------------------------------------------------- AC 3

#[test]
fn is_cached_false_when_any_one_file_is_missing() {
    let files = fx::required_files();
    assert!(
        files.len() >= 5,
        "model file plus 4 tokenizer files: {files:?}"
    );
    for missing in &files {
        let tmp = tempfile::tempdir().unwrap();
        fx::write_complete(tmp.path());
        assert!(is_cached(tmp.path()), "control: complete cache reads true");

        fs::remove_file(fx::snapshot_file(tmp.path(), missing)).unwrap();
        assert!(
            !is_cached(tmp.path()),
            "cache without {missing} (fastembed would download it) reads false"
        );
    }
}

#[cfg(unix)]
#[test]
fn is_cached_false_for_unfinished_download() {
    let tmp = tempfile::tempdir().unwrap();
    let files = fx::required_files();
    let (model_file, rest) = files.split_first().unwrap();

    // hf-hub mid-download of the model file: the other files are finished
    // and linked, the model's blob is still `<etag>.part` under its `.lock`,
    // and its snapshot pointer does not exist yet.
    for f in rest {
        fx::write_linked_file(tmp.path(), f);
    }
    fx::write_ref(tmp.path(), fx::COMMIT);
    let blob = fx::blob_path(tmp.path(), &fx::etag_for(model_file));
    fs::write(blob.with_extension("part"), b"partial onnx bytes").unwrap();
    fs::write(blob.with_extension("lock"), b"").unwrap();
    assert!(
        !is_cached(tmp.path()),
        "{model_file} still downloading (.part blob, no pointer) reads false"
    );

    // huggingface_hub (Python) names the same in-progress blob
    // `<etag>.incomplete`; a cache shared with it reads false the same way.
    fs::write(blob.with_extension("incomplete"), b"partial onnx bytes").unwrap();
    assert!(
        !is_cached(tmp.path()),
        "{model_file} still downloading (.incomplete blob, no pointer) reads false"
    );

    // A pointer whose blob is gone (cleaned up, or a broken link) is not
    // cached either: fastembed would re-download it.
    fs::remove_file(blob.with_extension("part")).unwrap();
    fs::remove_file(blob.with_extension("lock")).unwrap();
    fs::remove_file(blob.with_extension("incomplete")).unwrap();
    fx::write_linked_file(tmp.path(), model_file);
    fs::remove_file(&blob).unwrap();
    assert!(
        fs::symlink_metadata(fx::snapshot_file(tmp.path(), model_file)).is_ok(),
        "fixture: the dangling pointer is still there"
    );
    assert!(
        !is_cached(tmp.path()),
        "a snapshot pointer to a missing blob reads false"
    );

    // Control: the download finishes.
    fs::remove_file(fx::snapshot_file(tmp.path(), model_file)).unwrap();
    fx::write_linked_file(tmp.path(), model_file);
    assert!(
        is_cached(tmp.path()),
        "control: finished download reads true"
    );
}

#[test]
fn is_cached_false_when_ref_does_not_name_a_complete_snapshot() {
    let files = fx::required_files();

    // Snapshot complete but no refs/main: fastembed cannot resolve it and
    // would download.
    let tmp = tempfile::tempdir().unwrap();
    fx::write_snapshot_files(tmp.path(), fx::COMMIT, &files);
    assert!(
        !is_cached(tmp.path()),
        "complete snapshot without refs/main reads false"
    );
    fx::write_ref(tmp.path(), fx::COMMIT);
    assert!(
        is_cached(tmp.path()),
        "control: adding refs/main reads true"
    );

    // An update in progress: refs/main moved to a new commit whose snapshot
    // has only one file so far, while the old snapshot is complete.
    // fastembed looks files up under refs/main only, so it would download.
    let newer = "9e1f3c0b2a4d6e8f0a1b2c3d4e5f60718293a4b5";
    fx::write_snapshot_files(tmp.path(), newer, &files[..1]);
    fx::write_ref(tmp.path(), newer);
    assert!(
        !is_cached(tmp.path()),
        "refs/main naming an incomplete snapshot reads false"
    );
    fx::write_snapshot_files(tmp.path(), newer, &files);
    assert!(is_cached(tmp.path()), "control: the new snapshot completes");
}

#[test]
fn is_cached_false_for_model_files_outside_the_bge_small_repo_dir() {
    let files = fx::required_files();

    // Flat at the cache root (fastembed 3's layout): fastembed 5 never
    // looks there, so it would download.
    let flat = tempfile::tempdir().unwrap();
    for f in &files {
        let p = flat.path().join(f);
        fs::create_dir_all(p.parent().unwrap()).unwrap();
        fs::write(&p, format!("fake {f}\n")).unwrap();
    }
    assert!(
        !is_cached(flat.path()),
        "a flat file set is not fastembed's cache"
    );

    // The complete set, but in another model's repo dir (the quantized
    // BGE-small): BGE-small-en-v1.5 itself is not cached.
    let other = tempfile::tempdir().unwrap();
    fx::write_complete(other.path());
    let quantized =
        fastembed::TextEmbedding::get_model_info(&fastembed::EmbeddingModel::BGESmallENV15Q)
            .unwrap()
            .model_code
            .clone();
    assert_ne!(quantized, fx::model_code());
    let other_repo = other
        .path()
        .join(format!("models--{quantized}").replace('/', "--"));
    fs::rename(fx::repo_dir(other.path()), &other_repo).unwrap();
    assert!(
        !is_cached(other.path()),
        "the same files under {other_repo:?} are another model's cache"
    );
    // Control: moved back, it is BGE-small-en-v1.5's again.
    fs::rename(&other_repo, fx::repo_dir(other.path())).unwrap();
    assert!(is_cached(other.path()), "control: back in its own repo dir");
}

#[test]
fn is_cached_false_when_a_directory_sits_where_a_snapshot_file_should_be() {
    for target in fx::required_files() {
        let tmp = tempfile::tempdir().unwrap();
        fx::write_complete(tmp.path());
        assert!(is_cached(tmp.path()), "control: complete cache reads true");

        let at = fx::snapshot_file(tmp.path(), &target);
        fs::remove_file(&at).unwrap();
        fs::create_dir(&at).unwrap();
        assert!(at.exists(), "fixture: {at:?} exists, as a directory");
        assert!(
            !is_cached(tmp.path()),
            "a directory at {target} is not the file fastembed reads: reads false"
        );

        fs::remove_dir(&at).unwrap();
        fs::write(&at, "fake\n").unwrap();
        assert!(
            is_cached(tmp.path()),
            "control: a regular file back at {target} reads true"
        );
    }
}

// ---------------------------------------------------------------- AC 4

#[test]
fn is_cached_makes_no_network_access() {
    let wire = tripwire();
    assert_eq!(std::env::var("HF_ENDPOINT").unwrap(), wire.url);

    let tmp = tempfile::tempdir().unwrap();
    let complete = tmp.path().join("complete");
    fx::write_complete(&complete);
    let partial = tmp.path().join("partial");
    fx::write_complete(&partial);
    fs::remove_file(fx::snapshot_file(&partial, &fx::required_files()[0])).unwrap();
    let no_ref = tmp.path().join("no-ref");
    fx::write_snapshot_files(&no_ref, fx::COMMIT, &fx::required_files());
    let missing = tmp.path().join("missing");

    // Hang guard only: the call runs on a worker so a blocked network read
    // fails this test instead of hanging the suite.
    let (tx, rx) = std::sync::mpsc::channel();
    let dirs = [complete, partial, no_ref, missing];
    let worker_dirs = dirs.clone();
    std::thread::spawn(move || {
        let got: Vec<bool> = worker_dirs
            .iter()
            .map(|d| FastEmbedder::is_cached(d))
            .collect();
        tx.send(got).unwrap();
    });
    let got = rx
        .recv_timeout(Duration::from_secs(120))
        .expect("is_cached returned (hang guard)");

    assert_eq!(
        got,
        vec![true, false, false, false],
        "complete / partial / no-ref / missing with HF_ENDPOINT={}",
        wire.url
    );
    assert_eq!(
        wire.hits(),
        0,
        "is_cached opened no connection to HF_ENDPOINT"
    );
    assert!(
        !dirs[3].exists(),
        "nothing was downloaded into the missing dir"
    );
}

// ---------------------------------------------------------------- AC 6-7

fn seed(vault: &mut Vault, notes: &[(&str, &str)], embedder: Option<&dyn Embedder>) {
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
        .unwrap()
}

fn has_chunk_vec(vault: &Vault) -> bool {
    count(
        vault,
        "SELECT COUNT(*) FROM sqlite_master WHERE name = 'chunk_vec'",
    ) > 0
}

const NOTES: [(&str, &str); 3] = [
    ("Storage", "We chose SQLite because the app is local-first."),
    ("Search", "Hybrid search fuses BM25 with cosine similarity."),
    ("Lunch", "I had a sandwich. The bread was sourdough."),
];

#[test]
fn embedding_counts_without_chunk_vec_reports_zero_embedded() {
    let dir = tempfile::tempdir().unwrap();
    let mut vault = Vault::create(dir.path()).unwrap();
    seed(&mut vault, &NOTES, None);
    assert!(
        !has_chunk_vec(&vault),
        "fixture: FTS-only vault has no chunk_vec"
    );
    let chunks = count(&vault, "SELECT COUNT(*) FROM chunks");
    assert!(chunks >= 3, "fixture: every note has a chunk ({chunks})");

    let got = embedding_counts(vault.connection_ref()).unwrap();
    assert_eq!(
        got,
        EmbeddingCounts {
            chunks,
            embedded: 0
        }
    );
    // #394 serialises it as-is.
    assert_eq!(
        serde_json::to_value(got).unwrap(),
        serde_json::json!({ "chunks": chunks, "embedded": 0 })
    );
    assert!(
        !has_chunk_vec(&vault),
        "embedding_counts creates no chunk_vec"
    );
}

#[test]
fn embedding_counts_excludes_orphan_vectors() {
    let dir = tempfile::tempdir().unwrap();
    let mut vault = Vault::create(dir.path()).unwrap();
    let dim = 8;
    let emb = FakeEmbedder::new(dim);
    // Two notes embedded, one indexed without vectors (pending).
    seed(&mut vault, &NOTES[..2], Some(&emb));
    seed(&mut vault, &NOTES[2..], None);
    assert!(has_chunk_vec(&vault));

    let chunks = count(&vault, "SELECT COUNT(*) FROM chunks");
    let embedded = count(
        &vault,
        "SELECT COUNT(*) FROM chunks WHERE embed_model_version IS NOT NULL",
    );
    assert!(
        (2..chunks).contains(&embedded),
        "fixture: {embedded}/{chunks} embedded"
    );
    assert_eq!(count(&vault, "SELECT COUNT(*) FROM chunk_vec"), embedded);
    assert_eq!(
        embedding_counts(vault.connection_ref()).unwrap(),
        EmbeddingCounts { chunks, embedded },
        "before any orphan"
    );

    // An orphan: a vector whose chunk no longer exists.
    let mut unit = vec![0f32; dim];
    unit[0] = 1.0;
    let bytes: Vec<u8> = unit.iter().flat_map(|f| f.to_le_bytes()).collect();
    vault
        .connection_ref()
        .execute(
            "INSERT INTO chunk_vec (chunk_id, embedding) VALUES ('01ORPHANCHUNK0000000000000', ?)",
            [bytes],
        )
        .unwrap();
    assert_eq!(
        count(&vault, "SELECT COUNT(*) FROM chunk_vec"),
        embedded + 1,
        "fixture: chunk_vec holds the orphan"
    );

    assert_eq!(
        embedding_counts(vault.connection_ref()).unwrap(),
        EmbeddingCounts { chunks, embedded },
        "the orphan vector row is not counted"
    );
}

fn unit_vector_bytes(dim: usize) -> Vec<u8> {
    let mut unit = vec![0f32; dim];
    unit[0] = 1.0;
    unit.iter().flat_map(|f| f.to_le_bytes()).collect()
}

fn chunk_ids(vault: &Vault, where_sql: &str) -> Vec<String> {
    let mut stmt = vault
        .connection_ref()
        .prepare(&format!(
            "SELECT id FROM chunks WHERE {where_sql} ORDER BY id"
        ))
        .unwrap();
    let rows = stmt.query_map([], |r| r.get::<_, String>(0)).unwrap();
    rows.map(|r| r.unwrap()).collect()
}

/// `embedded` is the `chunk_vec` rows joined to chunks, not the chunks whose
/// `embed_model_version` is set: the two diverge when vectors are deleted or
/// the table is rebuilt (a dimension change) or `embed_missing` writes
/// vectors on its own.
#[test]
fn embedding_counts_follows_chunk_vec_rows_not_embed_model_version() {
    let dir = tempfile::tempdir().unwrap();
    let mut vault = Vault::create(dir.path()).unwrap();
    let dim = 8;
    let emb = FakeEmbedder::new(dim);
    seed(&mut vault, &NOTES[..2], Some(&emb));
    seed(&mut vault, &NOTES[2..], None);
    let chunks = count(&vault, "SELECT COUNT(*) FROM chunks");
    let embedded = count(&vault, "SELECT COUNT(*) FROM chunk_vec");
    assert!(
        (2..chunks).contains(&embedded),
        "fixture: {embedded}/{chunks} embedded"
    );
    assert_eq!(
        embedding_counts(vault.connection_ref()).unwrap(),
        EmbeddingCounts { chunks, embedded },
        "fixture: both sources agree to start with"
    );

    // A vector deleted: the chunk keeps its embed_model_version but has no
    // chunk_vec row, so it is unembedded.
    let stamped = chunk_ids(&vault, "embed_model_version IS NOT NULL");
    vault
        .connection_ref()
        .execute("DELETE FROM chunk_vec WHERE chunk_id = ?", [&stamped[0]])
        .unwrap();
    assert_eq!(
        count(
            &vault,
            "SELECT COUNT(*) FROM chunks WHERE embed_model_version IS NOT NULL"
        ),
        embedded,
        "fixture: embed_model_version still says {embedded} chunks are embedded"
    );
    assert_eq!(
        embedding_counts(vault.connection_ref()).unwrap(),
        EmbeddingCounts {
            chunks,
            embedded: embedded - 1
        },
        "a chunk whose vector row is gone is not embedded"
    );

    // A vector written for a chunk with no embed_model_version: it counts.
    let unstamped = chunk_ids(&vault, "embed_model_version IS NULL");
    assert!(!unstamped.is_empty(), "fixture: an unstamped chunk exists");
    vault
        .connection_ref()
        .execute(
            "INSERT INTO chunk_vec (chunk_id, embedding) VALUES (?, ?)",
            rusqlite::params![&unstamped[0], unit_vector_bytes(dim)],
        )
        .unwrap();
    assert_eq!(
        embedding_counts(vault.connection_ref()).unwrap(),
        EmbeddingCounts { chunks, embedded },
        "a chunk with a vector row is embedded whatever embed_model_version says"
    );
}

#[test]
fn embedding_counts_with_empty_chunk_vec_reports_zero_embedded() {
    let dir = tempfile::tempdir().unwrap();
    let mut vault = Vault::create(dir.path()).unwrap();
    seed(&mut vault, &NOTES, None);
    memex_core::schema::ensure_vector_table(vault.connection_ref(), 8).unwrap();
    assert!(has_chunk_vec(&vault));
    let chunks = count(&vault, "SELECT COUNT(*) FROM chunks");
    assert_eq!(
        embedding_counts(vault.connection_ref()).unwrap(),
        EmbeddingCounts {
            chunks,
            embedded: 0
        }
    );
}
