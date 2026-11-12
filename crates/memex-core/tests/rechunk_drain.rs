//! WI #418 (Spec #391 requirements 3 and 4, ruling D3): the one-time
//! rechunk drain and the `reindex_note` orphan fix.
//!
//! - `reindex_note` deletes the `chunk_vec` rows of a note's old chunks
//!   whenever `chunk_vec` exists, with or without an embedder.
//! - `Vault::open` drains `pending_index` right after `schema::apply`, one
//!   note per transaction, with `reindex_note(…, None)`: every queued note is
//!   rechunked by person section and the queue ends empty. A drain stopped
//!   partway finishes on the next open; two opens draining one root do no
//!   harm.
//! - After the rechunk, FTS and hybrid search still reach a daily-note
//!   passage's topic note through D25 expansion.
//!
//! "Legacy" chunks stand in for what the old whole-body chunker stored
//! before V7: one chunk per note holding the full body, frontmatter and
//! footer included. Real SQLite, real schema, temp vaults only, the
//! `FakeEmbedder` for vectors.

use std::collections::{BTreeMap, BTreeSet};
use std::fmt::Write as _;
use std::path::Path;
use std::sync::{Arc, Barrier, Mutex};

use memex_core::daily::TOPICS_MARKER;
use memex_core::embedder::{Embedder, FakeEmbedder};
use memex_core::footer::{self, ChipOrigin};
use memex_core::indexer;
use memex_core::notes::{create_note_as, get_note, CreateNote, Note, NoteId};
use memex_core::search::{search, SearchFilters, SearchHit, SearchMode, SearchOptions};
use memex_core::{schema, Caller, Vault};
use rusqlite::{params, Connection};
use serde_json::{json, Value};
use tempfile::TempDir;
use tracing::field::{Field, Visit};
use tracing::{span, Event, Metadata, Subscriber};

// ---- fixtures ---------------------------------------------------------------------------------

const DAY: &str = "2026-09-05";
const DIM: usize = 8;

fn fresh_vault() -> (TempDir, Vault) {
    let dir = tempfile::tempdir().unwrap();
    let vault = Vault::create(dir.path()).unwrap();
    (dir, vault)
}

fn reopen(root: &Path) -> Vault {
    Vault::open(root).unwrap_or_else(|e| panic!("open {}: {e}", root.display()))
}

fn reindex(vault: &mut Vault, id: &NoteId, body: &str, embedder: Option<&dyn Embedder>) {
    indexer::reindex_note(vault.connection_mut(), id.as_str(), body, embedder)
        .unwrap_or_else(|e| panic!("reindex {id}: {e}"));
}

/// A person-created note, reindexed from its stored body with `embedder`.
fn create(
    vault: &mut Vault,
    title: &str,
    body: &str,
    fm: Option<Value>,
    embedder: Option<&dyn Embedder>,
) -> Note {
    let note = create_note_as(
        vault,
        CreateNote {
            title: Some(title.into()),
            content_md: body.into(),
            frontmatter: fm,
        },
        Caller::Person,
    )
    .unwrap_or_else(|e| panic!("create {title}: {e}"));
    reindex(vault, &note.id, &note.content_md, embedder);
    note
}

fn topic_fm() -> Option<Value> {
    Some(json!({ "role": "topic" }))
}

fn daily_fm() -> Option<Value> {
    Some(json!({ "role": "daily" }))
}

fn stored_body(conn: &Connection, id: &NoteId) -> String {
    conn.query_row(
        "SELECT content_md FROM notes WHERE id = ?",
        [id.as_str()],
        |r| r.get(0),
    )
    .unwrap()
}

fn count(conn: &Connection, sql: &str) -> i64 {
    conn.query_row(sql, [], |r| r.get(0)).unwrap()
}

fn queued(conn: &Connection) -> BTreeSet<String> {
    let mut stmt = conn.prepare("SELECT note_id FROM pending_index").unwrap();
    let rows = stmt.query_map([], |r| r.get::<_, String>(0)).unwrap();
    rows.map(|r| r.unwrap()).collect()
}

fn enqueue(conn: &Connection, id: &NoteId) {
    conn.execute(
        "INSERT OR IGNORE INTO pending_index (note_id, enqueued_at) VALUES (?, 1)",
        [id.as_str()],
    )
    .unwrap();
}

/// `(content, start_byte, end_byte)` of a note's stored chunks, by ord.
fn chunks_of(conn: &Connection, id: &NoteId) -> Vec<(String, usize, usize)> {
    let mut stmt = conn
        .prepare(
            "SELECT content, start_byte, end_byte FROM chunks
             WHERE note_id = ? ORDER BY ord",
        )
        .unwrap();
    stmt.query_map([id.as_str()], |r| {
        Ok((
            r.get::<_, String>(0)?,
            r.get::<_, i64>(1)? as usize,
            r.get::<_, i64>(2)? as usize,
        ))
    })
    .unwrap()
    .collect::<Result<_, _>>()
    .unwrap()
}

/// The ids of a note's stored chunks, by ord.
fn chunk_ids(conn: &Connection, id: &NoteId) -> Vec<String> {
    let mut stmt = conn
        .prepare("SELECT id FROM chunks WHERE note_id = ? ORDER BY ord")
        .unwrap();
    let rows = stmt
        .query_map([id.as_str()], |r| r.get::<_, String>(0))
        .unwrap();
    rows.map(|r| r.unwrap()).collect()
}

/// The span of the first occurrence of `text` in `body`.
fn span_of(body: &str, text: &str) -> (String, usize, usize) {
    let start = body
        .find(text)
        .unwrap_or_else(|| panic!("{text:?} not in {body:?}"));
    (text.to_string(), start, start + text.len())
}

/// `chunk_vec` rows whose `chunk_id` is not in `chunks`.
fn orphan_vectors(conn: &Connection) -> i64 {
    count(
        conn,
        "SELECT COUNT(*) FROM chunk_vec WHERE chunk_id NOT IN (SELECT id FROM chunks)",
    )
}

/// `chunk_vec` rows of a note's current chunks.
fn vectors_of(conn: &Connection, id: &NoteId) -> i64 {
    conn.query_row(
        "SELECT COUNT(*) FROM chunk_vec
          WHERE chunk_id IN (SELECT id FROM chunks WHERE note_id = ?)",
        [id.as_str()],
        |r| r.get(0),
    )
    .unwrap()
}

fn has_table(conn: &Connection, name: &str) -> bool {
    conn.query_row(
        "SELECT COUNT(*) FROM sqlite_master WHERE name = ?",
        [name],
        |r| r.get::<_, i64>(0),
    )
    .unwrap()
        > 0
}

/// Replaces a note's chunks with one legacy whole-body chunk `LEGACY-<id>`
/// (and its FTS row), as the pre-V7 chunker stored it, and returns its id.
/// With `vector`, the legacy chunk also gets a `chunk_vec` row.
fn make_legacy(conn: &Connection, id: &NoteId, vector: bool) -> String {
    let body = stored_body(conn, id);
    let legacy = format!("LEGACY-{id}");
    for old in chunk_ids(conn, id) {
        conn.execute("DELETE FROM chunk_fts WHERE chunk_id = ?", [&old])
            .unwrap();
        if has_table(conn, "chunk_vec") {
            conn.execute("DELETE FROM chunk_vec WHERE chunk_id = ?", [&old])
                .unwrap();
        }
    }
    conn.execute("DELETE FROM chunks WHERE note_id = ?", [id.as_str()])
        .unwrap();
    conn.execute(
        "INSERT INTO chunks (id, note_id, ord, content, token_count, start_byte, end_byte)
         VALUES (?, ?, 0, ?, 1, 0, ?)",
        params![legacy, id.as_str(), body, body.len() as i64],
    )
    .unwrap();
    conn.execute(
        "INSERT INTO chunk_fts (chunk_id, note_id, content) VALUES (?, ?, ?)",
        params![legacy, id.as_str(), body],
    )
    .unwrap();
    if vector {
        schema::ensure_vector_table(conn, DIM).unwrap();
        conn.execute(
            "INSERT INTO chunk_vec (chunk_id, embedding) VALUES (?, '[1,0,0,0,0,0,0,0]')",
            [&legacy],
        )
        .unwrap();
    }
    legacy
}

fn fts(conn: &Connection, query: &str) -> Vec<SearchHit> {
    run_search(conn, query, SearchMode::Fts, None)
}

fn run_search(
    conn: &Connection,
    query: &str,
    mode: SearchMode,
    embedder: Option<&dyn Embedder>,
) -> Vec<SearchHit> {
    search(
        conn,
        SearchOptions {
            query,
            k: 10,
            mode,
            filters: SearchFilters::default(),
            embedder,
        },
    )
    .unwrap()
    .hits
}

/// `(note_title, via)` per hit, in order.
fn summary(hits: &[SearchHit]) -> Vec<(String, Option<String>)> {
    hits.iter()
        .map(|h| (h.note_title.clone(), h.via.clone()))
        .collect()
}

// ---- a small vault whose notes need the rechunk ------------------------------------------------

const TOPIC_BODY: &str = "---\nsummary: Quokkafrontmatter words\n---\nLoop notes on momentum.\n\n![[2026-09-05#^b7k2m9]]\n\nCoyote time helps.\n";

/// The notes of [`seeded`]: a topic with frontmatter, a transclusion-only
/// block and a footer chip; a daily note with a footer chip; a plain note;
/// and a chip-target topic.
struct Seeded {
    topic: Note,
    day: Note,
    plain: Note,
    chip: Note,
}

impl Seeded {
    /// The notes the drain is expected to rechunk.
    fn queued(&self) -> [&Note; 3] {
        [&self.topic, &self.day, &self.plain]
    }
}

fn seeded(vault: &mut Vault) -> Seeded {
    let chip = create(
        vault,
        "Zanzibar Plans",
        "All about the trip.\n",
        topic_fm(),
        None,
    );
    let topic = create(vault, "Player Loop", TOPIC_BODY, topic_fm(), None);
    let day = create(
        vault,
        DAY,
        "Café ☕ fixed the jump arc.\n\nSleep was bad.\n",
        daily_fm(),
        None,
    );
    let plain = create(
        vault,
        "Plain note",
        "Plain paragraph 🎉 one.\n\nPlain paragraph two.\n",
        None,
        None,
    );
    for host in [&topic.id, &day.id] {
        footer::set_chip(vault, host, &chip.id, ChipOrigin::Person, None)
            .unwrap_or_else(|e| panic!("set_chip {host}: {e}"));
    }
    for id in [&topic.id, &day.id] {
        let body = stored_body(vault.connection_ref(), id);
        assert!(
            body.contains(TOPICS_MARKER) && body.contains("[[Zanzibar Plans~about]]"),
            "precondition: {id} has a footer chip: {body:?}"
        );
    }
    Seeded {
        topic,
        day,
        plain,
        chip,
    }
}

/// The person-section chunks each seeded note must have after the rechunk.
fn expected_chunks(conn: &Connection, s: &Seeded) -> BTreeMap<String, Vec<(String, usize, usize)>> {
    let topic = stored_body(conn, &s.topic.id);
    let day = stored_body(conn, &s.day.id);
    let plain = stored_body(conn, &s.plain.id);
    BTreeMap::from([
        (
            s.topic.id.to_string(),
            vec![
                span_of(&topic, "Loop notes on momentum."),
                span_of(&topic, "Coyote time helps."),
            ],
        ),
        (
            s.day.id.to_string(),
            vec![span_of(
                &day,
                "Café ☕ fixed the jump arc.\n\nSleep was bad.",
            )],
        ),
        (
            s.plain.id.to_string(),
            vec![span_of(
                &plain,
                "Plain paragraph 🎉 one.\n\nPlain paragraph two.",
            )],
        ),
    ])
}

fn actual_chunks(conn: &Connection, s: &Seeded) -> BTreeMap<String, Vec<(String, usize, usize)>> {
    s.queued()
        .iter()
        .map(|n| (n.id.to_string(), chunks_of(conn, &n.id)))
        .collect()
}

/// Gives every queued seeded note a legacy chunk and queues it.
fn queue_legacy(conn: &Connection, s: &Seeded, vector: bool) -> Vec<String> {
    s.queued()
        .iter()
        .map(|n| {
            let legacy = make_legacy(conn, &n.id, vector);
            enqueue(conn, &n.id);
            legacy
        })
        .collect()
}

// ---- AC 6: no orphaned vectors after a save without an embedder ---------------------------------

#[test]
fn saving_a_note_without_an_embedder_leaves_no_orphaned_chunk_vec_rows() {
    let (_d, mut vault) = fresh_vault();
    let emb = FakeEmbedder::new(DIM);
    let note = create(
        &mut vault,
        "Embedded note",
        "First paragraph.\n\nSecond paragraph.\n",
        None,
        Some(&emb),
    );
    let other = create(
        &mut vault,
        "Other note",
        "Untouched words.\n",
        None,
        Some(&emb),
    );
    let conn = vault.connection_ref();
    assert!(vectors_of(conn, &note.id) > 0, "precondition: embedded");
    assert_eq!(orphan_vectors(conn), 0, "precondition: no orphans yet");
    let other_vectors = vectors_of(conn, &other.id);
    assert!(other_vectors > 0);

    // The local app's save path: reindex with no embedder.
    reindex(
        &mut vault,
        &note.id,
        "First paragraph, edited.\n\nSecond paragraph.\n",
        None,
    );
    let conn = vault.connection_ref();
    assert_eq!(
        orphan_vectors(conn),
        0,
        "the old chunks' vectors are deleted without an embedder"
    );
    assert_eq!(vectors_of(conn, &note.id), 0, "new chunks are unembedded");
    assert_eq!(
        vectors_of(conn, &other.id),
        other_vectors,
        "another note's vectors are kept"
    );
}

#[test]
fn a_core_save_without_an_embedder_leaves_no_orphaned_chunk_vec_rows() {
    let (_d, mut vault) = fresh_vault();
    let emb = FakeEmbedder::new(DIM);
    let chip = create(
        &mut vault,
        "Zanzibar Plans",
        "All about the trip.\n",
        topic_fm(),
        Some(&emb),
    );
    let day = create(
        &mut vault,
        DAY,
        "Fixed the jump arc.\n",
        daily_fm(),
        Some(&emb),
    );
    assert!(vectors_of(vault.connection_ref(), &day.id) > 0);

    // A footer write re-renders the day and reindexes it without an embedder.
    footer::set_chip(&mut vault, &day.id, &chip.id, ChipOrigin::Person, None).unwrap();
    assert_eq!(orphan_vectors(vault.connection_ref()), 0);
    assert!(
        vectors_of(vault.connection_ref(), &chip.id) > 0,
        "the chip topic keeps its vectors"
    );
}

#[test]
fn saving_without_an_embedder_and_without_chunk_vec_still_succeeds() {
    // Guards the other arm: no chunk_vec table, nothing to delete, no error.
    let (_d, mut vault) = fresh_vault();
    let note = create(&mut vault, "FTS only", "Some words.\n", None, None);
    reindex(&mut vault, &note.id, "Other words.\n", None);
    let conn = vault.connection_ref();
    assert!(!has_table(conn, "chunk_vec"), "no vector table is made");
    assert_eq!(chunks_of(conn, &note.id).len(), 1);
}

// ---- AC 7: the drain on open -------------------------------------------------------------------

#[test]
fn opening_a_vault_with_queued_notes_reindexes_each_by_person_section_and_empties_the_queue() {
    let (dir, mut vault) = fresh_vault();
    let s = seeded(&mut vault);
    let unqueued_legacy = make_legacy(vault.connection_ref(), &s.chip.id, false);
    let legacy = queue_legacy(vault.connection_ref(), &s, false);
    let expected = expected_chunks(vault.connection_ref(), &s);
    assert_eq!(queued(vault.connection_ref()).len(), 3, "precondition");
    drop(vault);

    let vault = reopen(dir.path());
    let conn = vault.connection_ref();
    assert_eq!(queued(conn), BTreeSet::new(), "the queue is drained");
    assert_eq!(
        actual_chunks(conn, &s),
        expected,
        "each queued note is rechunked by person section"
    );
    for id in &legacy {
        assert_eq!(
            count(
                conn,
                &format!("SELECT COUNT(*) FROM chunks WHERE id = '{id}'")
            ),
            0,
            "legacy chunk {id} is gone"
        );
        assert_eq!(
            count(
                conn,
                &format!("SELECT COUNT(*) FROM chunk_fts WHERE chunk_id = '{id}'")
            ),
            0,
            "legacy FTS row {id} is gone"
        );
    }
    assert!(
        fts(conn, "Quokkafrontmatter").is_empty(),
        "frontmatter words no longer match"
    );
    assert_eq!(
        chunk_ids(conn, &s.chip.id),
        vec![unqueued_legacy],
        "a note that was not queued is left alone"
    );
}

#[test]
fn the_drain_deletes_the_vectors_of_the_old_chunks() {
    let (dir, mut vault) = fresh_vault();
    let s = seeded(&mut vault);
    queue_legacy(vault.connection_ref(), &s, true);
    assert_eq!(
        count(vault.connection_ref(), "SELECT COUNT(*) FROM chunk_vec"),
        3,
        "precondition: every legacy chunk has a vector"
    );
    drop(vault);

    let vault = reopen(dir.path());
    let conn = vault.connection_ref();
    assert!(queued(conn).is_empty());
    assert_eq!(orphan_vectors(conn), 0, "no vector outlives its chunk");
    assert_eq!(count(conn, "SELECT COUNT(*) FROM chunk_vec"), 0);
}

// ---- AC 8: a drain stopped partway -------------------------------------------------------------

#[test]
fn a_drain_stopped_partway_finishes_on_the_next_open() {
    let (dir, mut vault) = fresh_vault();
    let s = seeded(&mut vault);
    queue_legacy(vault.connection_ref(), &s, false);
    let expected = expected_chunks(vault.connection_ref(), &s);

    // A drain that stopped after its first note: that note was reindexed
    // (which deletes its queue row) and committed; the rest are still queued.
    let body = stored_body(vault.connection_ref(), &s.topic.id);
    reindex(&mut vault, &s.topic.id, &body, None);
    let done_ids = chunk_ids(vault.connection_ref(), &s.topic.id);
    assert_eq!(
        queued(vault.connection_ref()),
        BTreeSet::from([s.day.id.to_string(), s.plain.id.to_string()]),
        "precondition: two rows left"
    );
    drop(vault);

    let vault = reopen(dir.path());
    let conn = vault.connection_ref();
    assert!(queued(conn).is_empty(), "the rest of the queue is drained");
    assert_eq!(actual_chunks(conn, &s), expected);
    assert_eq!(
        chunk_ids(conn, &s.topic.id),
        done_ids,
        "the note drained before the stop is not reindexed again"
    );
}

// ---- AC 9: two opens on one root ---------------------------------------------------------------

#[test]
fn two_vault_opens_on_one_root_one_after_the_other_while_rows_are_queued_both_succeed_with_the_same_chunks(
) {
    let (dir, mut vault) = fresh_vault();
    let s = seeded(&mut vault);
    queue_legacy(vault.connection_ref(), &s, false);
    let expected = expected_chunks(vault.connection_ref(), &s);
    drop(vault);

    let first = Vault::open(dir.path()).expect("the first open succeeds");
    assert!(
        queued(first.connection_ref()).is_empty(),
        "the first open drains"
    );
    let after_first = actual_chunks(first.connection_ref(), &s);
    assert_eq!(after_first, expected);

    // Rows queued again while the first vault is still open.
    for n in s.queued() {
        enqueue(first.connection_ref(), &n.id);
    }
    let second = Vault::open(dir.path()).expect("the second open succeeds");
    assert!(queued(second.connection_ref()).is_empty());
    assert_eq!(
        actual_chunks(second.connection_ref(), &s),
        after_first,
        "the second drain leaves the same chunks"
    );
    assert_eq!(
        actual_chunks(first.connection_ref(), &s),
        after_first,
        "the first vault reads the same chunks"
    );
    assert_eq!(
        count(
            second.connection_ref(),
            "SELECT COUNT(*) FROM chunks c JOIN chunk_fts f ON f.chunk_id = c.id"
        ),
        count(second.connection_ref(), "SELECT COUNT(*) FROM chunk_fts"),
        "no FTS row outlives its chunk"
    );
}

#[test]
fn two_vault_opens_draining_at_once_both_succeed_and_chunk_each_note_once() {
    let (dir, mut vault) = fresh_vault();
    let s = seeded(&mut vault);
    let mut extra = Vec::new();
    for i in 0..8 {
        let body = format!("---\nsummary: Quokkafrontmatter {i}\n---\nExtra note {i} words.\n");
        extra.push(create(&mut vault, &format!("Extra {i}"), &body, None, None));
    }
    queue_legacy(vault.connection_ref(), &s, false);
    for n in &extra {
        make_legacy(vault.connection_ref(), &n.id, false);
        enqueue(vault.connection_ref(), &n.id);
    }
    let expected = expected_chunks(vault.connection_ref(), &s);
    // Counts every chunk row ever inserted from here on, so a note
    // reindexed twice shows.
    vault
        .connection_ref()
        .execute_batch(
            "CREATE TABLE insert_log (note_id TEXT NOT NULL);
             CREATE TRIGGER log_insert AFTER INSERT ON chunks
             BEGIN INSERT INTO insert_log (note_id) VALUES (NEW.note_id); END;",
        )
        .unwrap();
    drop(vault);

    let barrier = Arc::new(Barrier::new(2));
    let handles: Vec<_> = (0..2)
        .map(|_| {
            let root = dir.path().to_path_buf();
            let barrier = Arc::clone(&barrier);
            std::thread::spawn(move || {
                barrier.wait();
                Vault::open(&root).map(|_| ()).map_err(|e| e.to_string())
            })
        })
        .collect();
    for h in handles {
        h.join().unwrap().expect("both opens succeed");
    }

    // Read the database directly: another `Vault::open` would drain again and
    // hide a drain that failed under contention.
    let raw = Connection::open(dir.path().join("memex.db")).unwrap();
    assert_eq!(
        queued(&raw),
        BTreeSet::new(),
        "the two drains between them emptied the queue"
    );
    assert_eq!(actual_chunks(&raw, &s), expected);
    for (i, n) in extra.iter().enumerate() {
        let body = stored_body(&raw, &n.id);
        assert_eq!(
            chunks_of(&raw, &n.id),
            vec![span_of(&body, &format!("Extra note {i} words."))],
            "extra note {i} is chunked by person section"
        );
    }
    assert_eq!(
        count(&raw, "SELECT COUNT(*) FROM chunk_fts"),
        count(&raw, "SELECT COUNT(*) FROM chunks"),
        "one FTS row per chunk"
    );
    assert_eq!(
        count(&raw, "SELECT COUNT(*) FROM insert_log"),
        count(
            &raw,
            &format!(
                "SELECT COUNT(*) FROM chunks WHERE note_id <> '{}'",
                s.chip.id
            )
        ),
        "each queued note was reindexed once: the second drain skipped what the first had done"
    );
}

// ---- AC 10: D25 expansion after the rechunk ----------------------------------------------------

/// A daily note with a footer chip for `topic_title`, and the block id of its
/// first block, everything embedded with `emb`.
fn day_with_chip(vault: &mut Vault, emb: &FakeEmbedder, topic: &Note) -> (Note, String) {
    let day = create(
        vault,
        DAY,
        "Fixed the jump arc.\n\nSleep was bad.\n",
        daily_fm(),
        Some(emb),
    );
    footer::set_chip(vault, &day.id, &topic.id, ChipOrigin::Person, Some(emb)).unwrap();
    let block: String = vault
        .connection_ref()
        .query_row(
            "SELECT block_id FROM blocks WHERE note_id = ? AND ord = 0",
            [day.id.as_str()],
            |r| r.get(0),
        )
        .unwrap();
    (day, block)
}

/// Sets a topic's body to `body`, reindexed with `emb`.
fn set_topic_body(vault: &mut Vault, id: &NoteId, body: &str, emb: &FakeEmbedder) {
    vault
        .connection_ref()
        .execute(
            "UPDATE notes SET content_md = ? WHERE id = ?",
            params![body, id.as_str()],
        )
        .unwrap();
    reindex(vault, id, body, Some(emb));
}

/// Queues every note of the vault with a legacy chunk, then reopens it, so
/// the drain rechunks everything.
fn rechunk_everything(dir: &TempDir, vault: Vault) -> Vault {
    let conn = vault.connection_ref();
    let ids: Vec<String> = {
        let mut stmt = conn.prepare("SELECT id FROM notes").unwrap();
        let rows = stmt.query_map([], |r| r.get::<_, String>(0)).unwrap();
        rows.map(|r| r.unwrap()).collect()
    };
    for id in &ids {
        let id = NoteId::parse(id).unwrap();
        make_legacy(conn, &id, true);
        enqueue(conn, &id);
    }
    drop(vault);
    let vault = reopen(dir.path());
    assert!(
        queued(vault.connection_ref()).is_empty(),
        "precondition: the rechunk ran"
    );
    vault
}

fn assert_found_through_d25(vault: &Vault, emb: &FakeEmbedder, topic_title: &str) {
    let conn = vault.connection_ref();
    for (mode, embedder) in [
        (SearchMode::Fts, None),
        (SearchMode::Hybrid, Some(emb as &dyn Embedder)),
    ] {
        assert_eq!(
            summary(&run_search(conn, "jump", mode, embedder)),
            vec![
                (DAY.to_string(), None),
                (topic_title.to_string(), Some(DAY.to_string())),
            ],
            "{mode:?}: the day's hit is followed by its topic via the date"
        );
    }
}

#[test]
fn fts_and_hybrid_search_find_a_daily_passage_topic_note_through_d25_after_the_rechunk() {
    let (dir, mut vault) = fresh_vault();
    let emb = FakeEmbedder::new(DIM);
    let topic = create(
        &mut vault,
        "Player Loop",
        "Loop notes on momentum.\n",
        topic_fm(),
        Some(&emb),
    );
    let (_day, block) = day_with_chip(&mut vault, &emb, &topic);
    let body = format!("Loop notes on momentum.\n\n![[{DAY}#^{block}]]\n\nCoyote time helps.\n");
    set_topic_body(&mut vault, &topic.id, &body, &emb);

    let vault = rechunk_everything(&dir, vault);
    assert_found_through_d25(&vault, &emb, "Player Loop");
}

#[test]
fn fts_and_hybrid_search_find_a_topic_made_only_of_transclusions_through_d25_after_the_rechunk() {
    // A filed topic is often only transclusion tokens, so after the rechunk
    // it has no chunk of its own; D25 must still reach it.
    let (dir, mut vault) = fresh_vault();
    let emb = FakeEmbedder::new(DIM);
    let topic = create(
        &mut vault,
        "Jump Log",
        "Placeholder.\n",
        topic_fm(),
        Some(&emb),
    );
    let (_day, block) = day_with_chip(&mut vault, &emb, &topic);
    set_topic_body(
        &mut vault,
        &topic.id,
        &format!("![[{DAY}#^{block}]]\n"),
        &emb,
    );

    let vault = rechunk_everything(&dir, vault);
    assert_found_through_d25(&vault, &emb, "Jump Log");
}

#[test]
fn a_note_saved_after_the_drain_is_not_queued_again_on_reopen() {
    // The drain only empties the queue; it never refills it.
    let (dir, mut vault) = fresh_vault();
    let s = seeded(&mut vault);
    queue_legacy(vault.connection_ref(), &s, false);
    drop(vault);
    let mut vault = reopen(dir.path());
    assert!(queued(vault.connection_ref()).is_empty());
    let saved = get_note(&vault, &s.plain.id).unwrap();
    reindex(&mut vault, &saved.id, &saved.content_md, None);
    let ids = chunk_ids(vault.connection_ref(), &s.plain.id);
    drop(vault);

    let vault = reopen(dir.path());
    assert!(queued(vault.connection_ref()).is_empty());
    assert_eq!(
        chunk_ids(vault.connection_ref(), &s.plain.id),
        ids,
        "an open with an empty queue reindexes nothing"
    );
}

// ---- capturing the drain's warnings ---------------------------------------------------------

/// A process-wide `tracing` subscriber that keeps every event as one
/// `LEVEL field=value …` line, tagged with the thread that logged it, so a
/// test can read what it logged without a subscriber crate. It is global
/// rather than scoped: a scoped default is invisible to a callsite that
/// another test thread registers first (tracing caches that interest).
struct CaptureLogs;

static LOGS: Mutex<Vec<(std::thread::ThreadId, String)>> = Mutex::new(Vec::new());

struct FieldText(String);

impl Visit for FieldText {
    fn record_debug(&mut self, field: &Field, value: &dyn std::fmt::Debug) {
        write!(self.0, " {}={:?}", field.name(), value).unwrap();
    }
}

impl Subscriber for CaptureLogs {
    fn enabled(&self, _: &Metadata<'_>) -> bool {
        true
    }
    fn new_span(&self, _: &span::Attributes<'_>) -> span::Id {
        span::Id::from_u64(1)
    }
    fn record(&self, _: &span::Id, _: &span::Record<'_>) {}
    fn record_follows_from(&self, _: &span::Id, _: &span::Id) {}
    fn event(&self, event: &Event<'_>) {
        let mut fields = FieldText(String::new());
        event.record(&mut fields);
        LOGS.lock().unwrap().push((
            std::thread::current().id(),
            format!("{}{}", event.metadata().level(), fields.0),
        ));
    }
    fn enter(&self, _: &span::Id) {}
    fn exit(&self, _: &span::Id) {}
}

/// Runs `f` and returns its result with every event it logged on this thread.
fn capture_logs<T>(f: impl FnOnce() -> T) -> (T, Vec<String>) {
    static INSTALL: std::sync::Once = std::sync::Once::new();
    INSTALL.call_once(|| {
        tracing::subscriber::set_global_default(CaptureLogs)
            .expect("no other global subscriber in this test binary");
    });
    let me = std::thread::current().id();
    LOGS.lock().unwrap().retain(|(t, _)| *t != me);
    let out = f();
    let lines = LOGS
        .lock()
        .unwrap()
        .iter()
        .filter(|(t, _)| *t == me)
        .map(|(_, l)| l.clone())
        .collect();
    (out, lines)
}

// ---- verify: D38, D36 and the drain's guards --------------------------------------------------

/// Ids of the chunks of a note, as a one-element check of "still legacy".
fn only_chunk(conn: &Connection, id: &NoteId) -> Vec<String> {
    chunk_ids(conn, id)
}

#[test]
fn a_note_whose_reindex_fails_during_the_drain_stays_queued_and_the_others_are_drained() {
    let (dir, mut vault) = fresh_vault();
    let s = seeded(&mut vault);
    let legacy = queue_legacy(vault.connection_ref(), &s, false);
    let expected = expected_chunks(vault.connection_ref(), &s);
    // queue_legacy returns in `s.queued()` order: topic, day, plain.
    let day_legacy = legacy[1].clone();
    // The drain runs in (enqueued_at, note_id) order and ULIDs made in one
    // millisecond have no order, so the failing note goes first: a drain that
    // stopped at the first failure would leave the others undrained.
    vault
        .connection_ref()
        .execute(
            "UPDATE pending_index SET enqueued_at = 0 WHERE note_id = ?",
            [s.day.id.as_str()],
        )
        .unwrap();
    vault
        .connection_ref()
        .execute_batch(&format!(
            "CREATE TRIGGER fail_one BEFORE INSERT ON chunks
             WHEN NEW.note_id = '{}'
             BEGIN SELECT RAISE(ABORT, 'forced failure'); END;",
            s.day.id
        ))
        .unwrap();
    drop(vault);

    let (opened, logs) = capture_logs(|| Vault::open(dir.path()));
    let vault = opened.expect("an open is not refused over one failing note");
    let warnings: Vec<&String> = logs
        .iter()
        .filter(|l| l.starts_with("WARN") && l.contains("rechunk drain"))
        .collect();
    assert_eq!(warnings.len(), 1, "one warning, for the one note: {logs:?}");
    assert!(
        warnings[0].contains(&format!("note_id={}", s.day.id)),
        "the warning names the failing note: {}",
        warnings[0]
    );
    for ok in [&s.topic, &s.plain] {
        assert!(
            !warnings[0].contains(ok.id.as_str()),
            "and only that note: {}",
            warnings[0]
        );
    }
    let conn = vault.connection_ref();
    assert_eq!(
        queued(conn),
        BTreeSet::from([s.day.id.to_string()]),
        "only the failing note stays queued"
    );
    assert_eq!(
        only_chunk(conn, &s.day.id),
        vec![day_legacy],
        "the failing note's transaction rolled back: its legacy chunk is intact"
    );
    let actual = actual_chunks(conn, &s);
    for n in [&s.topic, &s.plain] {
        assert_eq!(
            actual[&n.id.to_string()],
            expected[&n.id.to_string()],
            "the other queued notes are drained"
        );
    }
    conn.execute_batch("DROP TRIGGER fail_one").unwrap();
    drop(vault);

    let vault = reopen(dir.path());
    let conn = vault.connection_ref();
    assert!(
        queued(conn).is_empty(),
        "the next open retries and drains it"
    );
    assert_eq!(actual_chunks(conn, &s), expected);
}

/// Rewrites `manifest.json`'s `schema_version`, as a vault last opened by an
/// older release has it.
fn set_manifest_schema_version(root: &Path, version: i64) {
    let path = root.join("manifest.json");
    let mut manifest: Value = serde_json::from_slice(&std::fs::read(&path).unwrap()).unwrap();
    manifest["schema_version"] = json!(version);
    std::fs::write(&path, serde_json::to_vec_pretty(&manifest).unwrap()).unwrap();
}

fn manifest_schema_version(root: &Path) -> i64 {
    let manifest: Value =
        serde_json::from_slice(&std::fs::read(root.join("manifest.json")).unwrap()).unwrap();
    manifest["schema_version"].as_i64().unwrap()
}

#[test]
fn the_manifest_says_the_current_schema_version_after_an_open_whose_drain_leaves_a_note_queued() {
    let (dir, mut vault) = fresh_vault();
    let s = seeded(&mut vault);
    queue_legacy(vault.connection_ref(), &s, false);
    vault
        .connection_ref()
        .execute_batch(&format!(
            "CREATE TRIGGER fail_one BEFORE INSERT ON chunks
             WHEN NEW.note_id = '{}'
             BEGIN SELECT RAISE(ABORT, 'forced failure'); END;",
            s.day.id
        ))
        .unwrap();
    let current = schema::current_version(vault.connection_ref()).unwrap();
    drop(vault);
    set_manifest_schema_version(dir.path(), current - 1);

    let vault = reopen(dir.path());
    assert_eq!(
        queued(vault.connection_ref()),
        BTreeSet::from([s.day.id.to_string()]),
        "precondition: the drain left the failing note queued"
    );
    assert_eq!(
        manifest_schema_version(dir.path()),
        current,
        "the manifest is refreshed whatever the drain does"
    );
}

#[cfg(unix)]
#[test]
fn the_manifest_is_refreshed_before_the_drain_so_a_failed_refresh_leaves_the_queue_untouched() {
    // A drain stopped partway (a crash) must never leave an older
    // schema_version over a migrated database: a client of the older release
    // refuses a vault by its manifest alone. Not being able to write the
    // manifest stands in for the stop: nothing may have been drained yet.
    use std::os::unix::fs::PermissionsExt;

    let (dir, mut vault) = fresh_vault();
    let s = seeded(&mut vault);
    let legacy = queue_legacy(vault.connection_ref(), &s, false);
    let current = schema::current_version(vault.connection_ref()).unwrap();
    drop(vault);
    set_manifest_schema_version(dir.path(), current - 1);
    let manifest = dir.path().join("manifest.json");
    std::fs::set_permissions(&manifest, std::fs::Permissions::from_mode(0o444)).unwrap();
    if std::fs::OpenOptions::new()
        .write(true)
        .open(&manifest)
        .is_ok()
    {
        eprintln!("skipped: file permissions are not enforced here (running as root)");
        return;
    }

    assert!(
        Vault::open(dir.path()).is_err(),
        "an open that cannot refresh the manifest fails"
    );
    std::fs::set_permissions(&manifest, std::fs::Permissions::from_mode(0o644)).unwrap();
    let raw = Connection::open(dir.path().join("memex.db")).unwrap();
    assert_eq!(queued(&raw).len(), 3, "the drain had not started");
    for (n, legacy_id) in s.queued().iter().zip(&legacy) {
        assert_eq!(
            chunk_ids(&raw, &n.id),
            vec![legacy_id.clone()],
            "{} is still legacy",
            n.title
        );
    }
}

#[test]
fn the_drain_skips_a_note_that_is_no_longer_queued_when_its_turn_comes() {
    let (dir, mut vault) = fresh_vault();
    let s = seeded(&mut vault);
    let legacy = queue_legacy(vault.connection_ref(), &s, false);
    let conn = vault.connection_ref();
    // The drain order is (enqueued_at, note_id): topic, then day, then plain.
    for (n, at) in [(&s.topic, 1), (&s.day, 2), (&s.plain, 3)] {
        conn.execute(
            "UPDATE pending_index SET enqueued_at = ? WHERE note_id = ?",
            params![at, n.id.as_str()],
        )
        .unwrap();
    }
    // Reindexing the topic (as a concurrent save would) takes the day off the
    // queue after the drain listed it.
    conn.execute_batch(&format!(
        "CREATE TRIGGER dequeue_day AFTER INSERT ON chunks
         WHEN NEW.note_id = '{}'
         BEGIN DELETE FROM pending_index WHERE note_id = '{}'; END;",
        s.topic.id, s.day.id
    ))
    .unwrap();
    drop(vault);

    let vault = reopen(dir.path());
    let conn = vault.connection_ref();
    assert!(queued(conn).is_empty());
    assert_eq!(
        chunk_ids(conn, &s.day.id),
        vec![legacy[1].clone()],
        "a note reindexed elsewhere is not reindexed again from the drain's older view"
    );
    assert_ne!(
        chunk_ids(conn, &s.plain.id),
        vec![legacy[2].clone()],
        "the still-queued note after it is drained"
    );
}

#[test]
fn the_drain_deletes_a_queue_row_whose_note_is_gone_and_keeps_going() {
    let (dir, mut vault) = fresh_vault();
    let s = seeded(&mut vault);
    queue_legacy(vault.connection_ref(), &s, false);
    let expected = expected_chunks(vault.connection_ref(), &s);
    drop(vault);
    // The FK cascade normally prevents a row like this.
    let raw = Connection::open(dir.path().join("memex.db")).unwrap();
    raw.execute_batch("PRAGMA foreign_keys = OFF").unwrap();
    raw.execute(
        "INSERT INTO pending_index (note_id, enqueued_at) VALUES ('GHOST-NOTE', 0)",
        [],
    )
    .unwrap();
    drop(raw);

    let vault = reopen(dir.path());
    let conn = vault.connection_ref();
    assert_eq!(queued(conn), BTreeSet::new(), "the dangling row is removed");
    assert_eq!(actual_chunks(conn, &s), expected, "the rest is drained");
}

#[test]
fn a_failing_chunk_vec_delete_fails_the_reindex_and_changes_nothing() {
    let (_d, mut vault) = fresh_vault();
    let note = create(
        &mut vault,
        "Held note",
        "First paragraph.\n\nSecond paragraph.\n",
        None,
        None,
    );
    let before = chunk_ids(vault.connection_ref(), &note.id);
    assert!(!before.is_empty());
    // A chunk_vec whose deletes fail, standing in for any delete error.
    vault
        .connection_ref()
        .execute_batch(
            "CREATE TABLE chunk_vec (chunk_id TEXT, embedding BLOB);
             CREATE TRIGGER no_vec_delete BEFORE DELETE ON chunk_vec
             BEGIN SELECT RAISE(ABORT, 'forced vec failure'); END;
             INSERT INTO chunk_vec (chunk_id) SELECT id FROM chunks;",
        )
        .unwrap();

    let result = indexer::reindex_note(
        vault.connection_mut(),
        note.id.as_str(),
        "Replaced words.\n",
        None,
    );
    assert!(result.is_err(), "a chunk_vec delete error is not ignored");
    assert_eq!(
        chunk_ids(vault.connection_ref(), &note.id),
        before,
        "the failed reindex rolled back"
    );
}

#[test]
fn a_chunkless_topics_d25_hit_has_an_empty_chunk_id_ord_zero_and_the_transcluded_text_as_snippet() {
    let (_d, mut vault) = fresh_vault();
    let emb = FakeEmbedder::new(DIM);
    let topic = create(
        &mut vault,
        "Jump Log",
        "Placeholder.\n",
        topic_fm(),
        Some(&emb),
    );
    let (_day, block) = day_with_chip(&mut vault, &emb, &topic);
    set_topic_body(
        &mut vault,
        &topic.id,
        &format!("![[{DAY}#^{block}]]\n"),
        &emb,
    );
    let conn = vault.connection_ref();
    assert!(chunks_of(conn, &topic.id).is_empty(), "precondition");

    for (mode, embedder) in [
        (SearchMode::Fts, None),
        (SearchMode::Hybrid, Some(&emb as &dyn Embedder)),
    ] {
        let hits = run_search(conn, "jump", mode, embedder);
        let hit = hits
            .iter()
            .find(|h| h.note_id == topic.id.as_str())
            .unwrap_or_else(|| panic!("{mode:?}: the topic is expanded: {hits:?}"));
        assert_eq!(hit.chunk_id, "", "{mode:?}");
        assert_eq!(hit.ord, 0, "{mode:?}");
        assert_eq!(hit.via.as_deref(), Some(DAY), "{mode:?}");
        assert!(
            hit.snippet.contains("Fixed the jump arc."),
            "{mode:?}: the snippet is the transcluded text: {:?}",
            hit.snippet
        );
        assert!(
            !hit.snippet.contains("![["),
            "{mode:?}: never the raw token: {:?}",
            hit.snippet
        );
    }
}
