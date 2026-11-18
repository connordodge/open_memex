//! WI #71 (Spec #59 requirements 34-38, architect D10, D11): the Command
//! palette's core note-text search, `note_search::note_search`.
//!
//! - Mode is always hybrid. `Ready` embeds the query and fuses FTS and kNN
//!   ranks as `search::search` does (`semantic: "on"`); `NotDownloaded` and
//!   `Off` run FTS only (`model_not_downloaded`, `embeddings_off`); an
//!   embedder error runs FTS only (`unavailable`) and is never an `Err`.
//! - Each hit carries `start_byte` (`chunks.start_byte`, nullable), the
//!   note's role and day, and its `updated_at`; a transcluded topic hit keeps
//!   `via` and the topic's own chunk.
//! - With `Ready` and `pending_cap > 0`, up to `pending_cap` unembedded
//!   chunks get a vector first (`vectors::embed_missing`); a DB error there
//!   skips it, an embedder error answers keyword hits as `unavailable`.
//! - D10: the query vector is computed before one lease that covers FTS,
//!   kNN, enrichment and expansion; no lease is held across inference.
//!
//! Real SQLite, temp vaults only. Test embedders only, never a model
//! download. Concurrency tests wait on `GatedEmbedder`'s entered signal,
//! never on a wall-clock sleep.

use std::collections::BTreeSet;
use std::path::PathBuf;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::Mutex;
use std::time::Duration;

use memex_core::embedder::{Embedder, GatedEmbedder};
use memex_core::indexer;
use memex_core::note_search::{note_search, NoteSearch, NoteSearchHit, SearchEmbedder, Semantic};
use memex_core::notes::{create_note_as, CreateNote, Note};
use memex_core::search::{search, SearchFilters, SearchHit, SearchMode, SearchOptions};
use memex_core::vectors::{embedding_counts, ConnLease};
use memex_core::{Caller, MemexError, Result, Vault};
use rusqlite::{params, Connection};
use serde_json::{json, Value};
use tempfile::TempDir;

const DIM: usize = 4;
const DAY: &str = "2026-09-05";
/// A small daily body: one chunk, three blocks.
const DAY_BODY: &str = "Fixed the jump arc.\n\n- tried coyote time\n\nSleep was bad.\n";

// ---------------------------------------------------------------- embedders

/// Maps a text to an axis by its words, so meaning is set exactly:
/// "zebra" or "striped" -> axis 0, "kelp" -> axis 2, anything else -> axis 1.
/// Counts `embed_batch` calls and texts.
struct AxisEmbedder {
    calls: AtomicUsize,
    texts: AtomicUsize,
}

impl AxisEmbedder {
    fn new() -> Self {
        Self {
            calls: AtomicUsize::new(0),
            texts: AtomicUsize::new(0),
        }
    }

    fn calls(&self) -> usize {
        self.calls.load(Ordering::SeqCst)
    }
}

fn axis(i: usize) -> Vec<f32> {
    let mut v = vec![0.0; DIM];
    v[i] = 1.0;
    v
}

fn axis_of(text: &str) -> Vec<f32> {
    let t = text.to_lowercase();
    if t.contains("zebra") || t.contains("striped") {
        axis(0)
    } else if t.contains("kelp") {
        axis(2)
    } else {
        axis(1)
    }
}

impl Embedder for AxisEmbedder {
    fn model_version(&self) -> &str {
        "axis-v1"
    }

    fn dimension(&self) -> usize {
        DIM
    }

    fn embed_batch(&self, texts: &[String]) -> Result<Vec<Vec<f32>>> {
        self.calls.fetch_add(1, Ordering::SeqCst);
        self.texts.fetch_add(texts.len(), Ordering::SeqCst);
        Ok(texts.iter().map(|t| axis_of(t)).collect())
    }
}

/// Fails every call, as a model that cannot load or embed does.
struct FailingEmbedder {
    calls: AtomicUsize,
}

impl FailingEmbedder {
    fn new() -> Self {
        Self {
            calls: AtomicUsize::new(0),
        }
    }
}

impl Embedder for FailingEmbedder {
    fn model_version(&self) -> &str {
        "failing-v1"
    }

    fn dimension(&self) -> usize {
        DIM
    }

    fn embed_batch(&self, _texts: &[String]) -> Result<Vec<Vec<f32>>> {
        self.calls.fetch_add(1, Ordering::SeqCst);
        Err(MemexError::EmbedderInfer("the model failed to load".into()))
    }
}

/// Embeds chunk texts like [`AxisEmbedder`] but fails on the one query text.
struct QueryFailsEmbedder {
    query: String,
}

impl Embedder for QueryFailsEmbedder {
    fn model_version(&self) -> &str {
        "axis-v1"
    }

    fn dimension(&self) -> usize {
        DIM
    }

    fn embed_batch(&self, texts: &[String]) -> Result<Vec<Vec<f32>>> {
        if texts.iter().any(|t| t == &self.query) {
            return Err(MemexError::EmbedderInfer("query inference failed".into()));
        }
        Ok(texts.iter().map(|t| axis_of(t)).collect())
    }
}

// ---------------------------------------------------------------- fixtures

struct Fx {
    _dir: TempDir,
    db: PathBuf,
    vault: Vault,
}

fn new_vault() -> Fx {
    let dir = tempfile::tempdir().unwrap();
    let vault = Vault::create(dir.path()).unwrap();
    let db = dir.path().join("memex.db");
    Fx {
        _dir: dir,
        db,
        vault,
    }
}

/// `n` filler words that no test queries for.
fn filler(n: usize) -> String {
    const WORDS: [&str; 5] = ["lorem", "ipsum", "dolor", "sit", "amet"];
    (0..n)
        .map(|i| WORDS[i % WORDS.len()])
        .collect::<Vec<_>>()
        .join(" ")
}

/// Three blocks, each big enough to be its own chunk, with multibyte text
/// before every block, so the third chunk starts well past byte 0.
fn long_body() -> String {
    let f = filler(260);
    format!(
        "Café ☕ opening words. {f}\n\n\
         Naïve 🎉 middle words. {f}\n\n\
         Zoë 😀 nebula closing words. {f}\n"
    )
}

impl Fx {
    fn conn(&self) -> &Connection {
        self.vault.connection_ref()
    }

    fn create(
        &mut self,
        title: &str,
        body: &str,
        fm: Option<Value>,
        embedder: Option<&dyn Embedder>,
    ) -> Note {
        let note = create_note_as(
            &mut self.vault,
            CreateNote {
                title: Some(title.into()),
                content_md: body.into(),
                frontmatter: fm,
            },
            Caller::Person,
        )
        .unwrap_or_else(|e| panic!("create {title}: {e}"));
        indexer::reindex_note(
            self.vault.connection_mut(),
            note.id.as_str(),
            &note.content_md,
            embedder,
        )
        .unwrap();
        note
    }

    fn plain(&mut self, title: &str, body: &str) -> Note {
        self.create(title, body, None, None)
    }

    fn daily(&mut self, date: &str, body: &str) -> Note {
        self.create(date, body, Some(json!({ "role": "daily" })), None)
    }

    fn topic(&mut self, title: &str, body: &str) -> Note {
        self.create(title, body, Some(json!({ "role": "topic" })), None)
    }

    fn embedded_plain(&mut self, title: &str, body: &str, embedder: &dyn Embedder) -> Note {
        self.create(title, body, None, Some(embedder))
    }

    fn try_run(
        &mut self,
        query: &str,
        limit: usize,
        embedder: SearchEmbedder<'_>,
        pending_cap: usize,
    ) -> Result<NoteSearch> {
        let mut conn = self.vault.connection_mut();
        note_search(&mut conn, query, limit, embedder, pending_cap)
    }

    fn run(
        &mut self,
        query: &str,
        limit: usize,
        embedder: SearchEmbedder<'_>,
        pending_cap: usize,
    ) -> NoteSearch {
        self.try_run(query, limit, embedder, pending_cap)
            .unwrap_or_else(|e| panic!("note_search({query:?}) failed: {e}"))
    }

    /// `search::search` in FTS mode: the keyword ranking to match.
    fn fts(&self, query: &str, k: usize) -> Vec<SearchHit> {
        search(
            self.conn(),
            SearchOptions {
                query,
                k,
                mode: SearchMode::Fts,
                filters: SearchFilters::default(),
                embedder: None,
            },
        )
        .unwrap()
        .hits
    }

    fn chunk_start(&self, chunk_id: &str) -> Option<i64> {
        self.conn()
            .query_row(
                "SELECT start_byte FROM chunks WHERE id = ?",
                [chunk_id],
                |r| r.get(0),
            )
            .unwrap_or_else(|e| panic!("chunk {chunk_id}: {e}"))
    }

    fn set_updated_at(&self, note: &Note, ms: i64) {
        let n = self
            .conn()
            .execute(
                "UPDATE notes SET updated_at = ? WHERE id = ?",
                params![ms, note.id.as_str()],
            )
            .unwrap();
        assert_eq!(n, 1);
    }

    fn updated_at(&self, note_id: &str) -> i64 {
        self.conn()
            .query_row(
                "SELECT updated_at FROM notes WHERE id = ?",
                [note_id],
                |r| r.get(0),
            )
            .unwrap()
    }

    fn set_null_ranges(&self, note: &Note) {
        let n = self
            .conn()
            .execute(
                "UPDATE chunks SET start_byte = NULL, end_byte = NULL WHERE note_id = ?",
                [note.id.as_str()],
            )
            .unwrap();
        assert!(n > 0, "precondition: the note has chunks");
    }

    /// The block id at `ord` of a note.
    fn block_id(&self, note: &Note, ord: i64) -> String {
        self.conn()
            .query_row(
                "SELECT block_id FROM blocks WHERE note_id = ? AND ord = ?",
                params![note.id.as_str(), ord],
                |r| r.get(0),
            )
            .unwrap()
    }

    fn embedded(&self) -> i64 {
        embedding_counts(self.conn()).unwrap().embedded
    }

    fn unembedded(&self) -> i64 {
        let c = embedding_counts(self.conn()).unwrap();
        c.chunks - c.embedded
    }
}

/// A daily note and a topic with an Excerpt of its first block. The query
/// "jump" hits the day; the topic is found only through the day.
struct DayAndTopic {
    day: Note,
    topic: Note,
}

fn day_and_topic(fx: &mut Fx) -> DayAndTopic {
    let day = fx.daily(DAY, DAY_BODY);
    let block = fx.block_id(&day, 0);
    let topic = fx.topic(
        "Player Loop",
        &format!("Loop notes.\n\n![[{DAY}#^{block}]]\n"),
    );
    DayAndTopic { day, topic }
}

/// Notes that all say "quasar", ranked differently by BM25.
fn quasar_notes(fx: &mut Fx, n: usize) -> Vec<Note> {
    (0..n)
        .map(|i| {
            let body = format!("quasar {} {}", "quasar ".repeat(n - i), filler(5 + i * 7));
            fx.plain(&format!("Quasar {i}"), &body)
        })
        .collect()
}

/// `(note_id, chunk_id, via)` per hit, in order.
type Key = (String, String, Option<String>);

fn keys(hits: &[NoteSearchHit]) -> Vec<Key> {
    hits.iter()
        .map(|h| (h.note_id.clone(), h.chunk_id.clone(), h.via.clone()))
        .collect()
}

fn search_keys(hits: &[SearchHit]) -> Vec<Key> {
    hits.iter()
        .map(|h| (h.note_id.clone(), h.chunk_id.clone(), h.via.clone()))
        .collect()
}

fn titles(got: &NoteSearch) -> Vec<String> {
    got.hits.iter().map(|h| h.note_title.clone()).collect()
}

/// The wire string of `semantic`.
fn semantic(got: &NoteSearch) -> String {
    serde_json::to_value(got).unwrap()["semantic"]
        .as_str()
        .unwrap_or_default()
        .to_string()
}

fn the_hit<'a>(got: &'a NoteSearch, note: &Note) -> &'a NoteSearchHit {
    got.hits
        .iter()
        .find(|h| h.note_id == note.id.as_str() && h.via.is_none())
        .unwrap_or_else(|| panic!("no direct hit on {}: {:?}", note.title, titles(got)))
}

/// A savanna note that matches "zebra" by meaning only, a zoo note that
/// matches it by keyword and meaning, and an unrelated bread note, all
/// embedded with [`AxisEmbedder`].
fn meaning_vault(fx: &mut Fx, emb: &AxisEmbedder) {
    fx.embedded_plain("Zoo", "A zebra lives in the zoo.", emb);
    fx.embedded_plain("Savanna", "The striped horse grazes on grass.", emb);
    fx.embedded_plain("Bread", "Sourdough bread for lunch.", emb);
}

/// Releases the gate when dropped, so a failing assertion (or a run that
/// returns early) never leaves a run thread blocked inside `embed_batch`.
struct ReleaseOnDrop<'a>(&'a GatedEmbedder);

impl Drop for ReleaseOnDrop<'_> {
    fn drop(&mut self) {
        self.0.release();
    }
}

/// The vault server's shape: a lease locks a shared `Mutex<Connection>`
/// for each call, and counts how often it was taken.
struct MutexLease<'a> {
    conn: &'a Mutex<Connection>,
    leases: usize,
}

impl ConnLease for MutexLease<'_> {
    fn lease<R>(&mut self, f: impl FnOnce(&mut Connection) -> Result<R>) -> Result<R> {
        let mut guard = self.conn.lock().unwrap();
        self.leases += 1;
        f(&mut guard)
    }
}

/// Closes the vault and reopens its db as a bare connection for a mutex.
fn into_shared(fx: Fx) -> (TempDir, Mutex<Connection>) {
    let Fx { _dir, db, vault } = fx;
    drop(vault);
    let c = Connection::open(&db).unwrap();
    c.busy_timeout(Duration::from_secs(5)).unwrap();
    (_dir, Mutex::new(c))
}

// ---------------------------------------------------------------- AC 1: Off

#[test]
fn off_answers_keyword_hits_in_fts_rank_order_as_embeddings_off() {
    let mut fx = new_vault();
    quasar_notes(&mut fx, 4);
    fx.plain("Unrelated", "Nothing about the sky here.");
    let want = fx.fts("quasar", 8);
    assert_eq!(want.len(), 4, "precondition: four keyword matches");

    let got = fx.run("quasar", 8, SearchEmbedder::Off, 64);

    assert_eq!(
        keys(&got.hits),
        search_keys(&want),
        "the keyword hits, in search::search FTS order"
    );
    assert_eq!(semantic(&got), "embeddings_off");
    assert_eq!(got.semantic, Semantic::EmbeddingsOff);
    assert_eq!(got.query, "quasar", "the answer names its query");
    assert!(!got.truncated);
    assert_eq!(fx.embedded(), 0, "Off never embeds a pending chunk");
}

#[test]
fn off_takes_exactly_one_lease_and_answers_the_keyword_hits() {
    let mut fx = new_vault();
    quasar_notes(&mut fx, 3);
    let want = search_keys(&fx.fts("quasar", 8));
    assert_eq!(want.len(), 3, "precondition");
    let (_dir, shared) = into_shared(fx);

    let mut lease = MutexLease {
        conn: &shared,
        leases: 0,
    };
    let got = note_search(&mut lease, "quasar", 8, SearchEmbedder::Off, 64).unwrap();

    assert_eq!(keys(&got.hits), want);
    assert_eq!(
        lease.leases, 1,
        "one lease covers FTS, enrichment and expansion"
    );
}

// ---------------------------------------------------------------- AC 2: NotDownloaded

#[test]
fn not_downloaded_answers_keyword_hits_as_model_not_downloaded() {
    let mut fx = new_vault();
    quasar_notes(&mut fx, 3);
    let want = fx.fts("quasar", 8);
    assert_eq!(want.len(), 3, "precondition");

    let got = fx.run("quasar", 8, SearchEmbedder::NotDownloaded, 64);

    assert_eq!(keys(&got.hits), search_keys(&want));
    assert_eq!(semantic(&got), "model_not_downloaded");
    assert_eq!(got.semantic, Semantic::ModelNotDownloaded);
    assert_eq!(fx.embedded(), 0, "no embedder, no pending embedding");
}

// ---------------------------------------------------------------- AC 3: Ready

#[test]
fn ready_answers_hybrid_hits_including_a_meaning_only_match_as_on() {
    let mut fx = new_vault();
    let emb = AxisEmbedder::new();
    meaning_vault(&mut fx, &emb);
    let calls_before = emb.calls();

    let keyword_only = fx.run("zebra", 8, SearchEmbedder::Off, 0);
    assert_eq!(
        titles(&keyword_only),
        vec!["Zoo"],
        "keyword search alone never finds the savanna"
    );

    let got = fx.run("zebra", 8, SearchEmbedder::Ready(&emb), 0);

    assert_eq!(semantic(&got), "on");
    assert_eq!(got.semantic, Semantic::On);
    let t = titles(&got);
    assert_eq!(
        t.first().map(String::as_str),
        Some("Zoo"),
        "keyword and meaning together rank first: {t:?}"
    );
    assert_eq!(
        t.get(1).map(String::as_str),
        Some("Savanna"),
        "the meaning-only match comes next, above the unrelated note: {t:?}"
    );
    assert_eq!(
        emb.calls() - calls_before,
        1,
        "one batch embeds the query; nothing was pending"
    );
}

#[test]
fn ready_with_pending_cap_zero_takes_exactly_one_lease() {
    let mut fx = new_vault();
    let emb = AxisEmbedder::new();
    meaning_vault(&mut fx, &emb);
    let (_dir, shared) = into_shared(fx);

    let mut lease = MutexLease {
        conn: &shared,
        leases: 0,
    };
    let got = note_search(&mut lease, "zebra", 8, SearchEmbedder::Ready(&emb), 0).unwrap();

    assert_eq!(got.semantic, Semantic::On);
    assert!(
        got.hits.iter().any(|h| h.note_title == "Savanna"),
        "the vector arm ran: {:?}",
        titles(&got)
    );
    assert_eq!(
        lease.leases, 1,
        "one lease covers FTS, kNN, enrichment and expansion (D10)"
    );
}

#[test]
fn ready_on_a_vault_with_no_vector_table_still_answers_keyword_hits() {
    let mut fx = new_vault();
    quasar_notes(&mut fx, 3);
    let want = search_keys(&fx.fts("quasar", 8));
    assert_eq!(want.len(), 3, "precondition");
    let emb = AxisEmbedder::new();

    let got = fx
        .try_run("quasar", 8, SearchEmbedder::Ready(&emb), 0)
        .expect("a missing chunk_vec table is never an Err");

    assert_eq!(keys(&got.hits), want, "the kNN arm adds nothing");
    assert_eq!(
        got.semantic,
        Semantic::Unavailable,
        "on means the vector arm ran (requirement 35); no chunk_vec table, no vector arm"
    );
    assert_eq!(semantic(&got), "unavailable");
}

// ---------------------------------------------------------------- AC 4: failing embedder

#[test]
fn failing_embedder_answers_keyword_hits_as_unavailable() {
    let mut fx = new_vault();
    quasar_notes(&mut fx, 3);
    let want = search_keys(&fx.fts("quasar", 8));
    assert_eq!(want.len(), 3, "precondition");
    let failing = FailingEmbedder::new();

    let got = fx
        .try_run("quasar", 8, SearchEmbedder::Ready(&failing), 0)
        .expect("an embedder error is never an Err");

    assert_eq!(keys(&got.hits), want, "keyword hits only");
    assert_eq!(semantic(&got), "unavailable");
    assert_eq!(got.semantic, Semantic::Unavailable);
    assert!(
        failing.calls.load(Ordering::SeqCst) >= 1,
        "the query embedding was tried"
    );
}

#[test]
fn failing_embedder_during_pending_embedding_answers_keyword_hits_as_unavailable() {
    let mut fx = new_vault();
    quasar_notes(&mut fx, 3);
    let want = search_keys(&fx.fts("quasar", 8));
    assert!(fx.unembedded() > 0, "precondition: pending chunks");
    let failing = FailingEmbedder::new();

    let got = fx
        .try_run("quasar", 8, SearchEmbedder::Ready(&failing), 64)
        .expect("an embedder error while embedding pending chunks is never an Err");

    assert_eq!(keys(&got.hits), want);
    assert_eq!(got.semantic, Semantic::Unavailable);
    assert_eq!(fx.embedded(), 0, "nothing was embedded");
}

#[test]
fn embedder_failing_only_on_the_query_answers_keyword_hits_as_unavailable() {
    let mut fx = new_vault();
    quasar_notes(&mut fx, 3);
    let want = search_keys(&fx.fts("quasar", 8));
    assert_eq!(want.len(), 3, "precondition");
    let emb = QueryFailsEmbedder {
        query: "quasar".into(),
    };

    let got = fx
        .try_run("quasar", 8, SearchEmbedder::Ready(&emb), 64)
        .expect("a query inference error is never an Err");

    assert_eq!(keys(&got.hits), want);
    assert_eq!(got.semantic, Semantic::Unavailable);
}

// ---------------------------------------------------------------- AC 5: empty query

#[test]
fn empty_or_whitespace_query_answers_no_hits_and_calls_no_embedder() {
    let mut fx = new_vault();
    quasar_notes(&mut fx, 3);
    let emb = AxisEmbedder::new();
    let words = fx.run("quasar", 8, SearchEmbedder::Off, 0);
    assert_eq!(words.hits.len(), 3, "the same vault answers its words");
    let pending = fx.unembedded();
    assert!(pending > 0, "precondition: pending chunks");

    for q in ["", " ", "   ", "\t", "\n \t "] {
        for embedder in [
            SearchEmbedder::Ready(&emb),
            SearchEmbedder::NotDownloaded,
            SearchEmbedder::Off,
        ] {
            let got = fx
                .try_run(q, 8, embedder, 64)
                .unwrap_or_else(|e| panic!("query {q:?}: {e}"));
            assert!(got.hits.is_empty(), "query {q:?} answers no hits");
            assert!(!got.truncated, "query {q:?} is not truncated");
        }
    }
    assert_eq!(emb.calls(), 0, "an empty query never calls the embedder");
    assert_eq!(fx.unembedded(), pending, "nor embeds pending chunks");
}

// ---------------------------------------------------------------- AC 6: start_byte

#[test]
fn each_hit_start_byte_equals_its_chunk_start_byte() {
    let mut fx = new_vault();
    let long = fx.plain("Long Note", &long_body());
    fx.plain("Short Note", "A nebula seen once.");
    let DayAndTopic { .. } = day_and_topic(&mut fx);

    let got = fx.run("nebula", 8, SearchEmbedder::Off, 0);
    assert!(got.hits.len() >= 2, "nebula hits: {:?}", titles(&got));
    let long_hit = the_hit(&got, &long);
    let long_start = fx.chunk_start(&long_hit.chunk_id);
    assert!(
        long_start.is_some_and(|s| s > 0),
        "precondition: the matched chunk of the long note starts past byte 0"
    );
    for h in &got.hits {
        assert_eq!(
            h.start_byte.map(|s| s as i64),
            fx.chunk_start(&h.chunk_id),
            "start_byte of {} is its chunk's",
            h.note_title
        );
    }

    let got = fx.run("jump", 8, SearchEmbedder::Off, 0);
    assert_eq!(got.hits.len(), 2, "precondition: day and topic via");
    for h in &got.hits {
        assert_eq!(
            h.start_byte.map(|s| s as i64),
            fx.chunk_start(&h.chunk_id),
            "start_byte of {} (via {:?}) is its chunk's",
            h.note_title,
            h.via
        );
    }
}

#[test]
fn a_chunk_with_null_start_byte_yields_null_start_byte() {
    let mut fx = new_vault();
    let old = fx.plain("Indexed Before V5", "An old nebula note.");
    fx.set_null_ranges(&old);
    let fresh = fx.plain("Indexed Now", "A new nebula note.");

    let got = fx.run("nebula", 8, SearchEmbedder::Off, 0);

    assert_eq!(the_hit(&got, &old).start_byte, None);
    let fresh_hit = the_hit(&got, &fresh);
    assert!(
        fx.chunk_start(&fresh_hit.chunk_id).is_some(),
        "precondition: the fresh chunk has a stored range"
    );
    assert_eq!(
        fresh_hit.start_byte.map(|s| s as i64),
        fx.chunk_start(&fresh_hit.chunk_id),
        "a stored range still reads"
    );
    let json = serde_json::to_value(&got).unwrap();
    let old_json = json["hits"]
        .as_array()
        .unwrap()
        .iter()
        .find(|h| h["note_id"] == old.id.as_str())
        .unwrap();
    assert_eq!(old_json["start_byte"], Value::Null, "serialized as null");
}

// ---------------------------------------------------------------- AC 7: role, day, updated_at

#[test]
fn hits_carry_note_role_day_and_note_updated_at() {
    let mut fx = new_vault();
    let day = fx.daily(DAY, "A nebula over the field.\n");
    let topic = fx.topic("Sky Topic", "Nebula catalogue.");
    let plain = fx.plain("Plain Note", "Nebula sketches.");
    let other = fx.create(
        "Project Note",
        "Nebula project.",
        Some(json!({ "role": "project" })),
        None,
    );
    fx.set_updated_at(&day, 1_731_900_000_001);
    fx.set_updated_at(&topic, 1_731_900_000_002);
    fx.set_updated_at(&plain, 1_731_900_000_003);
    fx.set_updated_at(&other, 1_731_900_000_004);

    let got = fx.run("nebula", 8, SearchEmbedder::Off, 0);

    let d = the_hit(&got, &day);
    assert_eq!(d.note_role.as_deref(), Some("daily"));
    assert_eq!(d.day.as_deref(), Some(DAY));
    let t = the_hit(&got, &topic);
    assert_eq!(t.note_role.as_deref(), Some("topic"));
    assert_eq!(t.day, None);
    let p = the_hit(&got, &plain);
    assert_eq!(p.note_role, None, "no role");
    assert_eq!(p.day, None);
    let o = the_hit(&got, &other);
    assert_eq!(
        o.note_role, None,
        "a role other than daily or topic is null"
    );
    assert_eq!(o.day, None);
    for h in &got.hits {
        assert_eq!(
            h.note_updated_at,
            fx.updated_at(&h.note_id),
            "note_updated_at of {}",
            h.note_title
        );
    }
    assert_eq!(d.note_updated_at, 1_731_900_000_001);
    assert_eq!(o.note_updated_at, 1_731_900_000_004);
}

// ---------------------------------------------------------------- AC 8: via

#[test]
fn a_topic_with_an_excerpt_of_a_matching_day_is_a_hit_via_that_day() {
    let mut fx = new_vault();
    let DayAndTopic { day, topic } = day_and_topic(&mut fx);
    let want = fx.fts("jump", 8);
    assert_eq!(
        want.iter().map(|h| h.via.clone()).collect::<Vec<_>>(),
        vec![None, Some(DAY.to_string())],
        "precondition: search::search expands the day into the topic"
    );

    let got = fx.run("jump", 8, SearchEmbedder::Off, 0);

    assert_eq!(
        keys(&got.hits),
        search_keys(&want),
        "the hits search::search produces"
    );
    let via = &got.hits[1];
    assert_eq!(via.note_id, topic.id.as_str());
    assert_eq!(via.via.as_deref(), Some(DAY));
    assert_eq!(via.note_role.as_deref(), Some("topic"));
    assert_eq!(via.day, None, "the topic has no day of its own");
    assert_eq!(via.chunk_id, want[1].chunk_id, "the topic's own chunk");
    assert_eq!(
        via.snippet, want[1].snippet,
        "the text search::search shows for it"
    );
    assert_eq!(got.hits[0].note_id, day.id.as_str());
    assert_eq!(got.hits[0].via, None);
}

#[test]
fn ready_also_expands_a_matching_day_into_its_topic() {
    let mut fx = new_vault();
    let DayAndTopic { topic, .. } = day_and_topic(&mut fx);
    let emb = AxisEmbedder::new();

    let got = fx.run("jump", 8, SearchEmbedder::Ready(&emb), 64);

    assert_eq!(got.semantic, Semantic::On);
    assert!(
        got.hits
            .iter()
            .any(|h| h.note_id == topic.id.as_str() && h.via.as_deref() == Some(DAY)),
        "the topic is a hit via the day: {:?}",
        keys(&got.hits)
    );
}

// ---------------------------------------------------------------- AC 9: limit, truncated

#[test]
fn limit_caps_the_hits_and_truncated_says_more_matched() {
    let mut fx = new_vault();
    quasar_notes(&mut fx, 5);
    let all = search_keys(&fx.fts("quasar", 20));
    assert_eq!(all.len(), 5, "precondition");

    let got = fx.run("quasar", 3, SearchEmbedder::Off, 0);
    assert_eq!(keys(&got.hits), all[..3].to_vec(), "the best 3");
    assert!(got.truncated, "two more matched");

    let got = fx.run("quasar", 4, SearchEmbedder::Off, 0);
    assert_eq!(got.hits.len(), 4);
    assert!(got.truncated, "one more matched");

    let got = fx.run("quasar", 5, SearchEmbedder::Off, 0);
    assert_eq!(keys(&got.hits), all, "exactly the matches");
    assert!(!got.truncated, "nothing more matched at limit == matches");

    let got = fx.run("quasar", 6, SearchEmbedder::Off, 0);
    assert_eq!(got.hits.len(), 5);
    assert!(!got.truncated);
}

#[test]
fn truncated_is_true_when_the_limit_drops_a_via_hit() {
    let mut fx = new_vault();
    let DayAndTopic { day, .. } = day_and_topic(&mut fx);

    let got = fx.run("jump", 1, SearchEmbedder::Off, 0);

    assert_eq!(got.hits.len(), 1);
    assert_eq!(got.hits[0].note_id, day.id.as_str());
    assert!(got.truncated, "the topic via the day was dropped");
}

#[test]
fn any_limit_answers_without_panicking() {
    let mut fx = new_vault();
    quasar_notes(&mut fx, 5);
    let emb = AxisEmbedder::new();
    let got = fx.run("quasar", 0, SearchEmbedder::Off, 0);
    assert!(got.hits.is_empty(), "limit 0 answers no hits");

    for limit in [
        20,
        4096,
        1 << 40,
        i64::MAX as usize,
        (i64::MAX as usize) + 1,
        usize::MAX,
    ] {
        let got = fx
            .try_run("quasar", limit, SearchEmbedder::Off, 0)
            .unwrap_or_else(|e| panic!("limit {limit}: {e}"));
        assert_eq!(got.hits.len(), 5, "limit {limit} answers every match");
        assert!(!got.truncated, "limit {limit}");
        let got = fx
            .try_run("quasar", limit, SearchEmbedder::Ready(&emb), 0)
            .unwrap_or_else(|e| panic!("Ready, limit {limit}: {e}"));
        assert!(
            got.hits.len() >= 5,
            "Ready, limit {limit} answers at least every keyword match"
        );
    }
}

#[test]
fn ready_with_a_large_limit_still_runs_the_vector_arm() {
    let mut fx = new_vault();
    let emb = AxisEmbedder::new();
    meaning_vault(&mut fx, &emb);
    fx.embedded_plain("Plains", "The striped horses graze at dusk.", &emb);

    for limit in [1000, 4096, 5000, 1 << 40, i64::MAX as usize, usize::MAX] {
        let got = fx
            .try_run("zebra", limit, SearchEmbedder::Ready(&emb), 0)
            .unwrap_or_else(|e| panic!("Ready, limit {limit}: {e}"));
        let t = titles(&got);
        assert_eq!(
            got.semantic,
            Semantic::On,
            "limit {limit}: the kNN k is clamped, so the vector arm runs: {t:?}"
        );
        for meaning_only in ["Savanna", "Plains"] {
            assert!(
                t.iter().any(|x| x == meaning_only),
                "limit {limit}: the kNN returns every close vector, {meaning_only} missing: {t:?}"
            );
        }
    }
}

// ---------------------------------------------------------------- AC 10: pending embedding

#[test]
fn ready_with_pending_cap_64_embeds_up_to_64_pending_chunks() {
    let mut fx = new_vault();
    for i in 0..70 {
        fx.plain(
            &format!("Pending {i}"),
            &format!("pending chunk number {i}"),
        );
    }
    assert!(fx.unembedded() >= 70, "precondition: 70+ pending chunks");
    let emb = AxisEmbedder::new();

    fx.run("pending", 8, SearchEmbedder::Ready(&emb), 64);

    assert_eq!(fx.embedded(), 64, "exactly pending_cap chunks get a vector");
}

#[test]
fn ready_with_pending_cap_zero_embeds_no_pending_chunk() {
    let mut fx = new_vault();
    quasar_notes(&mut fx, 3);
    let pending = fx.unembedded();
    assert!(pending > 0, "precondition");
    let emb = AxisEmbedder::new();

    let got = fx.run("quasar", 8, SearchEmbedder::Ready(&emb), 0);

    assert_eq!(got.hits.len(), 3, "the search still answers");
    assert_eq!(fx.embedded(), 0, "pending_cap 0 embeds nothing");
    assert_eq!(fx.unembedded(), pending);
    assert_eq!(emb.texts.load(Ordering::SeqCst), 1, "only the query text");
}

#[test]
fn pending_chunks_are_embedded_before_the_search_so_a_meaning_only_match_is_found() {
    let emb = AxisEmbedder::new();

    let mut fx = new_vault();
    fx.embedded_plain("Zoo", "A zebra lives in the zoo.", &emb);
    fx.plain("Savanna", "The striped horse grazes on grass.");
    let got = fx.run("zebra", 8, SearchEmbedder::Ready(&emb), 64);
    assert!(
        titles(&got).contains(&"Savanna".to_string()),
        "the savanna chunk got its vector before the kNN: {:?}",
        titles(&got)
    );

    let mut fx = new_vault();
    fx.embedded_plain("Zoo", "A zebra lives in the zoo.", &emb);
    fx.plain("Savanna", "The striped horse grazes on grass.");
    let got = fx.run("zebra", 8, SearchEmbedder::Ready(&emb), 0);
    assert_eq!(got.semantic, Semantic::On);
    assert_eq!(
        titles(&got),
        vec!["Zoo"],
        "with pending_cap 0 the savanna has no vector to find"
    );
}

// ---------------------------------------------------------------- AC 11: DB error while embedding

#[test]
fn a_db_error_while_embedding_pending_chunks_still_answers_the_hits() {
    let mut fx = new_vault();
    let emb = AxisEmbedder::new();
    fx.embedded_plain("Zoo", "A zebra lives in the zoo.", &emb);
    fx.plain("Savanna", "The striped horse grazes on grass.");
    fx.plain("Quasar", "A zebra quasar.");
    let embedded_before = fx.embedded();
    assert!(fx.unembedded() > 0, "precondition: pending chunks");

    // Another writer holds the write lock; this connection gives up at once
    // (SQLITE_BUSY), as it would after the 5 s busy_timeout.
    fx.vault
        .connection_mut()
        .busy_timeout(Duration::ZERO)
        .unwrap();
    let writer = Connection::open(&fx.db).unwrap();
    writer.execute_batch("BEGIN IMMEDIATE").unwrap();

    let got = fx
        .try_run("zebra", 8, SearchEmbedder::Ready(&emb), 64)
        .expect("a DB error in pending embedding is never an Err");

    writer.execute_batch("ROLLBACK").unwrap();
    let t = titles(&got);
    assert!(t.contains(&"Zoo".to_string()), "keyword hits: {t:?}");
    assert!(t.contains(&"Quasar".to_string()), "keyword hits: {t:?}");
    assert_eq!(
        got.semantic,
        Semantic::On,
        "embedding was skipped, the query was still embedded"
    );
    assert_eq!(fx.embedded(), embedded_before, "nothing was written");
}

// ---------------------------------------------------------------- AC 12: no lease across inference

#[test]
fn another_connection_takes_the_lease_while_the_query_embedding_is_blocked() {
    let mut fx = new_vault();
    let emb = AxisEmbedder::new();
    meaning_vault(&mut fx, &emb);
    let gated = GatedEmbedder::new(AxisEmbedder::new());
    let (_dir, shared) = into_shared(fx);

    let (got, leases) = std::thread::scope(|s| {
        let _release = ReleaseOnDrop(&gated);
        let run = s.spawn(|| {
            let _release = ReleaseOnDrop(&gated);
            let mut lease = MutexLease {
                conn: &shared,
                leases: 0,
            };
            let got = note_search(&mut lease, "zebra", 8, SearchEmbedder::Ready(&gated), 0);
            (got, lease.leases)
        });

        assert!(
            gated.wait_entered(),
            "note_search returned without embedding the query"
        );
        {
            let guard = shared
                .try_lock()
                .expect("the vault lease is free while the query is embedded");
            guard
                .execute(
                    "UPDATE notes SET title = 'Zoo Renamed' WHERE title = 'Zoo'",
                    [],
                )
                .expect("another connection writes through the free lease");
        }
        gated.release();
        run.join().unwrap()
    });

    let got = got.expect("the search answers");
    assert_eq!(got.semantic, Semantic::On);
    assert_eq!(
        titles(&got),
        vec!["Zoo Renamed", "Savanna", "Bread"],
        "the search ran after the embedding, on the renamed note"
    );
    assert_eq!(leases, 1, "one lease, taken after the query vector");
    assert_eq!(gated.calls(), 1);
}

#[test]
fn the_lease_is_free_while_pending_chunks_are_embedded() {
    let mut fx = new_vault();
    let emb = AxisEmbedder::new();
    fx.embedded_plain("Zoo", "A zebra lives in the zoo.", &emb);
    fx.plain("Savanna", "The striped horse grazes on grass.");
    let gated = GatedEmbedder::new(AxisEmbedder::new());
    let (_dir, shared) = into_shared(fx);

    let got = std::thread::scope(|s| {
        let _release = ReleaseOnDrop(&gated);
        let run = s.spawn(|| {
            let _release = ReleaseOnDrop(&gated);
            let mut lease = MutexLease {
                conn: &shared,
                leases: 0,
            };
            note_search(&mut lease, "zebra", 8, SearchEmbedder::Ready(&gated), 64)
        });

        assert!(
            gated.wait_entered(),
            "note_search returned without calling the embedder"
        );
        assert!(
            shared.try_lock().is_ok(),
            "the vault lease is free during the first inference"
        );
        gated.release();
        run.join().unwrap()
    });

    let got = got.expect("the search answers");
    assert!(
        titles(&got).contains(&"Savanna".to_string()),
        "the pending chunk was embedded, then found: {:?}",
        titles(&got)
    );
    assert_eq!(gated.calls(), 2, "one pending batch, then the query");
}

// ---------------------------------------------------------------- AC 13: wire shape

fn assert_date(v: &Value, what: &str) {
    let s = v
        .as_str()
        .unwrap_or_else(|| panic!("{what} is a string: {v}"));
    assert!(
        chrono::NaiveDate::parse_from_str(s, "%Y-%m-%d").is_ok() && s.len() == 10,
        "{what} is YYYY-MM-DD: {s}"
    );
}

#[test]
fn note_search_serializes_to_the_exact_requirement_34_shape() {
    let mut fx = new_vault();
    let DayAndTopic { .. } = day_and_topic(&mut fx);
    let old = fx.plain("Old Jump Note", "A jump indexed long ago.");
    fx.set_null_ranges(&old);
    fx.plain("Plain Jump", "Another jump.");

    let got = fx.run("jump", 8, SearchEmbedder::Off, 0);
    let v = serde_json::to_value(&got).unwrap();

    let top: BTreeSet<&str> = v.as_object().unwrap().keys().map(String::as_str).collect();
    assert_eq!(
        top,
        BTreeSet::from(["query", "semantic", "hits", "truncated"]),
        "exact top-level keys"
    );
    assert_eq!(v["query"], json!("jump"));
    assert!(v["semantic"].is_string());
    assert!(v["truncated"].is_boolean());
    let hits = v["hits"].as_array().expect("hits is an array");
    assert_eq!(hits.len(), 4, "day, topic via day, old note, plain note");

    let want_keys = BTreeSet::from([
        "note_id",
        "note_title",
        "note_role",
        "day",
        "chunk_id",
        "snippet",
        "start_byte",
        "via",
        "note_updated_at",
    ]);
    let (mut role_null, mut role_set) = (false, false);
    let (mut day_null, mut day_set) = (false, false);
    let (mut start_null, mut start_set) = (false, false);
    let (mut via_null, mut via_set) = (false, false);
    for h in hits {
        let keys: BTreeSet<&str> = h.as_object().unwrap().keys().map(String::as_str).collect();
        assert_eq!(keys, want_keys, "exact hit keys, nulls included: {h}");
        assert!(h["note_id"].is_string());
        assert!(h["note_title"].is_string());
        assert!(h["chunk_id"].is_string());
        assert!(h["snippet"].is_string());
        assert!(h["note_updated_at"].is_i64(), "note_updated_at is an int");
        match &h["note_role"] {
            Value::Null => role_null = true,
            r => {
                assert!(r == "daily" || r == "topic", "note_role: {r}");
                role_set = true;
            }
        }
        match &h["day"] {
            Value::Null => day_null = true,
            d => {
                assert_date(d, "day");
                day_set = true;
            }
        }
        match &h["start_byte"] {
            Value::Null => start_null = true,
            b => {
                assert!(b.is_u64(), "start_byte is a non-negative int: {b}");
                start_set = true;
            }
        }
        match &h["via"] {
            Value::Null => via_null = true,
            d => {
                assert_date(d, "via");
                via_set = true;
            }
        }
    }
    assert!(role_null && role_set, "note_role seen as null and set");
    assert!(day_null && day_set, "day seen as null and set");
    assert!(start_null && start_set, "start_byte seen as null and set");
    assert!(via_null && via_set, "via seen as null and set");
}

#[test]
fn semantic_serializes_to_its_four_wire_strings() {
    let mut fx = new_vault();
    quasar_notes(&mut fx, 2);
    let emb = AxisEmbedder::new();
    let failing = FailingEmbedder::new();

    // `on` needs the vector arm to have run, so its row embeds the pending
    // chunks (cap 64) and builds the vector table first.
    let cases: [(SearchEmbedder<'_>, usize, &str); 4] = [
        (SearchEmbedder::Ready(&emb), 64, "on"),
        (SearchEmbedder::NotDownloaded, 0, "model_not_downloaded"),
        (SearchEmbedder::Off, 0, "embeddings_off"),
        (SearchEmbedder::Ready(&failing), 0, "unavailable"),
    ];
    for (embedder, cap, want) in cases {
        let got = fx.run("quasar", 8, embedder, cap);
        assert_eq!(got.hits.len(), 2, "{want}: the keyword hits");
        assert_eq!(semantic(&got), want);
    }
}

// ---------------------------------------------------------------- verify: embedder error sources (D11)

/// Embeds like [`AxisEmbedder`] for a single text, but fails a batch of
/// several (the pending chunks) with an error that is not an embedder error.
struct BatchFailsWithOtherErrorEmbedder;

impl Embedder for BatchFailsWithOtherErrorEmbedder {
    fn model_version(&self) -> &str {
        "axis-v1"
    }

    fn dimension(&self) -> usize {
        DIM
    }

    fn embed_batch(&self, texts: &[String]) -> Result<Vec<Vec<f32>>> {
        if texts.len() > 1 {
            return Err(MemexError::NotFound("the model runtime".into()));
        }
        Ok(texts.iter().map(|t| axis_of(t)).collect())
    }
}

/// Embeds like [`AxisEmbedder`] for a single text, but answers one vector
/// short for a batch of several (the pending chunks).
struct BatchAnswersShortEmbedder;

impl Embedder for BatchAnswersShortEmbedder {
    fn model_version(&self) -> &str {
        "axis-v1"
    }

    fn dimension(&self) -> usize {
        DIM
    }

    fn embed_batch(&self, texts: &[String]) -> Result<Vec<Vec<f32>>> {
        let n = if texts.len() > 1 {
            texts.len() - 1
        } else {
            texts.len()
        };
        Ok(texts.iter().take(n).map(|t| axis_of(t)).collect())
    }
}

/// Answers an empty vector for the query.
struct EmptyQueryVectorEmbedder;

impl Embedder for EmptyQueryVectorEmbedder {
    fn model_version(&self) -> &str {
        "empty-v1"
    }

    fn dimension(&self) -> usize {
        DIM
    }

    fn embed_batch(&self, texts: &[String]) -> Result<Vec<Vec<f32>>> {
        Ok(texts.iter().map(|_| Vec::new()).collect())
    }
}

#[test]
fn a_non_embedder_error_from_pending_inference_answers_keyword_hits_as_unavailable() {
    let mut fx = new_vault();
    quasar_notes(&mut fx, 3);
    let want = search_keys(&fx.fts("quasar", 8));
    assert!(fx.unembedded() > 1, "precondition: several pending chunks");

    let got = fx
        .try_run(
            "quasar",
            8,
            SearchEmbedder::Ready(&BatchFailsWithOtherErrorEmbedder),
            64,
        )
        .expect("an embedder failure while embedding pending chunks is never an Err");

    assert_eq!(keys(&got.hits), want);
    assert_eq!(got.semantic, Semantic::Unavailable);
}

#[test]
fn an_embedder_answering_too_few_vectors_for_pending_chunks_answers_unavailable() {
    let mut fx = new_vault();
    quasar_notes(&mut fx, 3);
    let want = search_keys(&fx.fts("quasar", 8));
    assert!(fx.unembedded() > 1, "precondition: several pending chunks");

    let got = fx
        .try_run(
            "quasar",
            8,
            SearchEmbedder::Ready(&BatchAnswersShortEmbedder),
            64,
        )
        .expect("a vector-count mismatch is never an Err");

    assert_eq!(keys(&got.hits), want);
    assert_eq!(got.semantic, Semantic::Unavailable);
}

#[test]
fn an_empty_query_vector_answers_keyword_hits_as_unavailable() {
    let mut fx = new_vault();
    quasar_notes(&mut fx, 3);
    let want = search_keys(&fx.fts("quasar", 8));

    let got = fx
        .try_run(
            "quasar",
            8,
            SearchEmbedder::Ready(&EmptyQueryVectorEmbedder),
            0,
        )
        .expect("an empty query vector is never an Err");

    assert_eq!(keys(&got.hits), want);
    assert_eq!(got.semantic, Semantic::Unavailable);
}

// ---------------------------------------------------------------- verify: role and day edge cases

#[test]
fn a_daily_note_whose_title_is_not_a_date_has_no_day() {
    let mut fx = new_vault();
    let note = fx.daily(DAY, "Nebula over the field.\n");
    fx.conn()
        .execute(
            "UPDATE notes SET title = 'Not a date' WHERE id = ?",
            [note.id.as_str()],
        )
        .unwrap();

    let got = fx.run("nebula", 8, SearchEmbedder::Off, 0);

    let h = the_hit(&got, &note);
    assert_eq!(h.note_role.as_deref(), Some("daily"));
    assert_eq!(h.day, None, "a title that is not an ISO date is no day");
}

#[test]
fn a_non_text_role_in_the_frontmatter_is_no_role_and_not_an_error() {
    let mut fx = new_vault();
    let note = fx.plain("Odd Role", "Nebula catalogue.");
    fx.conn()
        .execute(
            "UPDATE notes SET frontmatter = '{\"role\": 5}' WHERE id = ?",
            [note.id.as_str()],
        )
        .unwrap();

    let got = fx
        .try_run("nebula", 8, SearchEmbedder::Off, 0)
        .expect("a numeric role is never an Err");

    let h = the_hit(&got, &note);
    assert_eq!(h.note_role, None);
    assert_eq!(h.day, None);
}
