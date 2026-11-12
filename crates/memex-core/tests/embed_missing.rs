//! #420 (Spec #391 req 5 and 16): `vectors::embed_missing` embeds unembedded
//! chunks through a [`ConnLease`], never holding the vault connection (or a
//! write transaction) across inference.
//!
//! Concurrency tests drive a [`GatedEmbedder`]: they wait on its entered
//! signal and release it, never on a wall-clock sleep. Each run thread
//! releases the gate when `embed_missing` returns, so a run that never calls
//! the embedder fails `wait_entered` at once instead of hanging.

use std::path::PathBuf;
use std::sync::Mutex;
use std::time::Duration;

use memex_core::embedder::{Embedder, GatedEmbedder, TableEmbedder};
use memex_core::notes::{create_note, CreateNote};
use memex_core::schema;
use memex_core::vectors::{embed_missing, embedding_counts, ConnLease, EmbedMissing};
use memex_core::{MemexError, Result, Vault};
use rusqlite::{params, Connection, OptionalExtension};

const DIM: usize = 4;

// ---------------------------------------------------------------- fixtures

struct Fx {
    _dir: tempfile::TempDir,
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

impl Fx {
    fn conn(&self) -> &Connection {
        self.vault.connection_ref()
    }

    /// A note with no chunks of its own (the test adds them).
    fn note(&mut self, title: &str) -> String {
        let n = create_note(
            &mut self.vault,
            CreateNote {
                title: Some(title.to_string()),
                content_md: String::new(),
                ..Default::default()
            },
        )
        .unwrap();
        let id = n.id.as_str().to_string();
        self.conn()
            .execute("DELETE FROM chunks WHERE note_id = ?", [&id])
            .unwrap();
        id
    }

    fn chunk(&self, id: &str, note: &str, ord: i64) {
        self.chunk_with_model(id, note, ord, None);
    }

    fn chunk_with_model(&self, id: &str, note: &str, ord: i64, model: Option<&str>) {
        let content = text(id);
        self.conn()
            .execute(
                "INSERT INTO chunks
                    (id, note_id, ord, content, token_count, embed_model_version,
                     start_byte, end_byte)
                 VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
                params![id, note, ord, content, 3, model, 0, content.len() as i64],
            )
            .unwrap();
    }

    /// Writes a vector row directly (an earlier embed, or an orphan).
    fn put_vec(&self, chunk_id: &str, v: &[f32]) {
        put_vec(self.conn(), chunk_id, v);
    }

    fn vec_of(&self, chunk_id: &str) -> Option<Vec<f32>> {
        vec_of(self.conn(), chunk_id)
    }

    fn vec_ids(&self) -> Vec<String> {
        let mut stmt = self
            .conn()
            .prepare("SELECT chunk_id FROM chunk_vec ORDER BY chunk_id")
            .unwrap();
        let rows = stmt.query_map([], |r| r.get::<_, String>(0)).unwrap();
        rows.map(|r| r.unwrap()).collect()
    }

    fn has_chunk_vec(&self) -> bool {
        chunk_vec_sql(self.conn()).is_some()
    }

    fn remainder(&self) -> usize {
        let c = embedding_counts(self.conn()).unwrap();
        (c.chunks - c.embedded) as usize
    }

    fn revision(&self) -> i64 {
        self.conn()
            .query_row("SELECT n FROM content_revision WHERE id = 1", [], |r| {
                r.get(0)
            })
            .unwrap()
    }

    fn chunks_snapshot(&self) -> Vec<ChunkRow> {
        let mut stmt = self
            .conn()
            .prepare(
                "SELECT id, note_id, ord, content, token_count, embed_model_version,
                        start_byte, end_byte
                   FROM chunks ORDER BY id",
            )
            .unwrap();
        let rows = stmt
            .query_map([], |r| {
                Ok(ChunkRow {
                    id: r.get(0)?,
                    note_id: r.get(1)?,
                    ord: r.get(2)?,
                    content: r.get(3)?,
                    token_count: r.get(4)?,
                    embed_model_version: r.get(5)?,
                    start_byte: r.get(6)?,
                    end_byte: r.get(7)?,
                })
            })
            .unwrap();
        rows.map(|r| r.unwrap()).collect()
    }

    /// Runs `embed_missing` with the vault's own connection as the lease.
    fn run(
        &mut self,
        embedder: &dyn Embedder,
        note_first: Option<&str>,
        note_cap: usize,
        others_cap: usize,
    ) -> Result<EmbedMissing> {
        let mut conn = self.vault.connection_mut();
        embed_missing(&mut conn, embedder, note_first, note_cap, others_cap)
    }

    /// A second connection to the same vault that never waits for a lock.
    fn other_writer(&self) -> Connection {
        let c = Connection::open(&self.db).unwrap();
        c.busy_timeout(Duration::ZERO).unwrap();
        c
    }
}

#[derive(Debug, PartialEq)]
struct ChunkRow {
    id: String,
    note_id: String,
    ord: i64,
    content: String,
    token_count: i64,
    embed_model_version: Option<String>,
    start_byte: i64,
    end_byte: i64,
}

/// A ULID-shaped chunk id (26 chars) that sorts by `n`.
fn cid(n: u32) -> String {
    format!("01K{n:023}")
}

fn text(chunk_id: &str) -> String {
    format!("passage of chunk {chunk_id}")
}

/// The vector the table embedder gives chunk `id`: distinct per chunk.
fn vec_for(chunk_id: &str) -> Vec<f32> {
    let n: u32 = chunk_id[3..].parse().unwrap();
    vec![n as f32 + 1.0, 1.0, 0.5, -(n as f32)]
}

/// An earlier embed's vector, unlike any `vec_for`.
const PRE: [f32; DIM] = [0.0, 0.0, 1.0, 0.0];

fn table_for(fx: &Fx) -> TableEmbedder {
    let mut t = TableEmbedder::new(DIM);
    for row in fx.chunks_snapshot() {
        t.insert(row.content.clone(), vec_for(&row.id));
    }
    t
}

fn put_vec(conn: &Connection, chunk_id: &str, v: &[f32]) {
    schema::ensure_vector_table(conn, v.len()).unwrap();
    conn.execute(
        "INSERT INTO chunk_vec (chunk_id, embedding) VALUES (?, ?)",
        params![chunk_id, le_bytes(v)],
    )
    .unwrap();
}

fn vec_of(conn: &Connection, chunk_id: &str) -> Option<Vec<f32>> {
    conn.query_row(
        "SELECT embedding FROM chunk_vec WHERE chunk_id = ?",
        [chunk_id],
        |r| r.get::<_, Vec<u8>>(0),
    )
    .optional()
    .unwrap()
    .map(|b| {
        b.chunks_exact(4)
            .map(|c| f32::from_le_bytes([c[0], c[1], c[2], c[3]]))
            .collect()
    })
}

fn chunk_vec_sql(conn: &Connection) -> Option<String> {
    conn.query_row(
        "SELECT sql FROM sqlite_master WHERE name = 'chunk_vec'",
        [],
        |r| r.get(0),
    )
    .optional()
    .unwrap()
}

fn le_bytes(v: &[f32]) -> Vec<u8> {
    v.iter().flat_map(|f| f.to_le_bytes()).collect()
}

fn sorted(ids: &[u32]) -> Vec<String> {
    let mut v: Vec<String> = ids.iter().map(|n| cid(*n)).collect();
    v.sort();
    v
}

/// Note A (5 chunks; ord 0 already embedded; ids deliberately out of `ord`
/// order, and A holds the lowest unembedded id), plus notes B and C
/// (3 chunks each, B's first already embedded), inserted out of id order.
///
/// Unembedded: A by ord = [40, 30, 1, 20]; others by id = [2, 3, 9, 12, 15].
struct Seeded {
    fx: Fx,
    a: String,
}

fn seeded() -> Seeded {
    let mut fx = new_vault();
    let a = fx.note("Note A");
    let b = fx.note("Note B");
    let c = fx.note("Note C");
    // C first, then B, then A: rowid order is not id order.
    fx.chunk(&cid(9), &c, 0);
    fx.chunk(&cid(2), &c, 1);
    fx.chunk(&cid(15), &c, 2);
    fx.chunk(&cid(5), &b, 0);
    fx.chunk(&cid(12), &b, 1);
    fx.chunk(&cid(3), &b, 2);
    fx.chunk(&cid(20), &a, 4);
    fx.chunk(&cid(1), &a, 3);
    fx.chunk(&cid(30), &a, 2);
    fx.chunk(&cid(40), &a, 1);
    fx.chunk(&cid(50), &a, 0);
    fx.put_vec(&cid(50), &PRE);
    fx.put_vec(&cid(5), &PRE);
    assert_eq!(fx.remainder(), 9, "fixture: 9 of 11 chunks unembedded");
    Seeded { fx, a }
}

/// Asserts each of `ids` now has exactly its table vector.
fn assert_table_vectors(fx: &Fx, ids: &[u32]) {
    for n in ids {
        assert_eq!(
            fx.vec_of(&cid(*n)),
            Some(vec_for(&cid(*n))),
            "chunk {} has the vector of its own text",
            cid(*n)
        );
    }
}

/// Releases the gate when dropped, so a failing assertion (or a run that
/// returns early) never leaves a run thread blocked inside `embed_batch`.
struct ReleaseOnDrop<'a>(&'a GatedEmbedder);

impl Drop for ReleaseOnDrop<'_> {
    fn drop(&mut self) {
        self.0.release();
    }
}

/// Three unembedded chunks on two notes; `chunk_vec` already exists.
fn three_unembedded() -> Fx {
    let mut fx = new_vault();
    let a = fx.note("Gate A");
    let b = fx.note("Gate B");
    fx.chunk(&cid(1), &a, 0);
    fx.chunk(&cid(2), &b, 0);
    fx.chunk(&cid(3), &b, 1);
    schema::ensure_vector_table(fx.conn(), DIM).unwrap();
    fx
}

// ---------------------------------------------------------------- AC 1

#[test]
fn embeds_note_first_chunks_by_ord_then_lowest_id_others() {
    let Seeded { mut fx, a } = seeded();
    let table = table_for(&fx);

    let got = fx.run(&table, Some(&a), 2, 3).unwrap();

    assert_eq!(
        got,
        EmbedMissing {
            embedded: 5,
            pending: 4
        },
        "A's ord 1-2 plus the 3 lowest-id other chunks; 4 left"
    );
    assert_eq!(
        fx.vec_ids(),
        sorted(&[50, 5, 40, 30, 2, 3, 9]),
        "A by ord (40, 30), not A by id (1, 20); others by id (2, 3, 9), never A's"
    );
    assert_table_vectors(&fx, &[40, 30, 2, 3, 9]);
    assert_eq!(
        fx.vec_of(&cid(50)),
        Some(PRE.to_vec()),
        "earlier vector kept"
    );
    assert_eq!(
        fx.vec_of(&cid(5)),
        Some(PRE.to_vec()),
        "earlier vector kept"
    );
    assert_eq!(
        got.pending,
        fx.remainder(),
        "pending is the true remainder (embedding_counts chunks - embedded)"
    );
}

#[test]
fn caps_larger_than_the_unembedded_set_embed_everything() {
    let Seeded { mut fx, a } = seeded();
    let table = table_for(&fx);

    // note_cap exactly A's 4 unembedded chunks; others_cap above the 5 others.
    let got = fx.run(&table, Some(&a), 4, 6).unwrap();

    assert_eq!(
        got,
        EmbedMissing {
            embedded: 9,
            pending: 0
        }
    );
    assert_table_vectors(&fx, &[40, 30, 1, 20, 2, 3, 9, 12, 15]);
    assert_eq!(fx.remainder(), 0);
}

// ---------------------------------------------------------------- AC 2

#[test]
fn note_cap_zero_embeds_none_of_note_first() {
    let Seeded { mut fx, a } = seeded();
    let table = table_for(&fx);

    let got = fx.run(&table, Some(&a), 0, 3).unwrap();

    assert_eq!(
        got,
        EmbedMissing {
            embedded: 3,
            pending: 6
        }
    );
    assert_eq!(
        fx.vec_ids(),
        sorted(&[50, 5, 2, 3, 9]),
        "no chunk of A; the 3 lowest-id others"
    );
    assert_table_vectors(&fx, &[2, 3, 9]);
}

#[test]
fn others_cap_zero_embeds_only_note_first() {
    let Seeded { mut fx, a } = seeded();
    let table = table_for(&fx);

    let got = fx.run(&table, Some(&a), 2, 0).unwrap();

    assert_eq!(
        got,
        EmbedMissing {
            embedded: 2,
            pending: 7
        }
    );
    assert_eq!(
        fx.vec_ids(),
        sorted(&[50, 5, 40, 30]),
        "A's first 2 unembedded by ord; no other note's chunk"
    );
    assert_table_vectors(&fx, &[40, 30]);
}

#[test]
fn note_first_none_embeds_only_others() {
    let Seeded { mut fx, a: _ } = seeded();
    let table = table_for(&fx);

    // With no note_first every note is "other": note_cap picks nothing, and
    // others go by ascending id across all notes (A's id 1 included).
    let got = fx.run(&table, None, 2, 3).unwrap();

    assert_eq!(
        got,
        EmbedMissing {
            embedded: 3,
            pending: 6
        }
    );
    assert_eq!(fx.vec_ids(), sorted(&[50, 5, 1, 2, 3]));
    assert_table_vectors(&fx, &[1, 2, 3]);
}

#[test]
fn note_first_with_nothing_unembedded_still_embeds_others() {
    let Seeded { mut fx, a } = seeded();
    let table = table_for(&fx);

    // A note with no chunks at all, then an unknown id: A counts as "other".
    let empty = fx.note("Empty note");
    let got = fx.run(&table, Some(&empty), 2, 3).unwrap();
    assert_eq!(
        got,
        EmbedMissing {
            embedded: 3,
            pending: 6
        }
    );
    assert_eq!(fx.vec_ids(), sorted(&[50, 5, 1, 2, 3]));

    let got = fx.run(&table, Some("no-such-note"), 2, 1).unwrap();
    assert_eq!(
        got,
        EmbedMissing {
            embedded: 1,
            pending: 5
        }
    );
    assert_table_vectors(&fx, &[9]);

    // A itself once all its chunks are embedded: note_cap finds none.
    let got = fx.run(&table, Some(&a), 4, 0).unwrap();
    assert_eq!(got.embedded, 3, "A's 40, 30, 20 (1 is done)");
    let got = fx.run(&table, Some(&a), 4, 1).unwrap();
    assert_eq!(
        got,
        EmbedMissing {
            embedded: 1,
            pending: 1
        },
        "nothing of A left; one other (12)"
    );
    assert_table_vectors(&fx, &[40, 30, 20, 12]);
}

#[test]
fn caps_of_zero_pick_nothing_and_never_call_the_embedder() {
    let Seeded { mut fx, a } = seeded();
    let table = table_for(&fx);

    let got = fx.run(&table, Some(&a), 0, 0).unwrap();

    assert_eq!(
        got,
        EmbedMissing {
            embedded: 0,
            pending: 9
        },
        "nothing picked; all 9 still pending"
    );
    assert_eq!(table.calls(), 0, "embedder never called");
    assert_eq!(fx.vec_ids(), sorted(&[50, 5]));
}

// ---------------------------------------------------------------- AC 3

#[test]
fn every_run_deletes_orphan_vectors_even_when_nothing_is_embedded() {
    let mut fx = new_vault();
    let a = fx.note("Orphans");
    fx.chunk(&cid(1), &a, 0);
    fx.chunk(&cid(2), &a, 1);
    fx.put_vec(&cid(1), &PRE);
    fx.put_vec(&cid(2), &PRE);
    // Orphans: a vector whose chunk was deleted, and one that never had one.
    fx.chunk(&cid(7), &a, 2);
    fx.put_vec(&cid(7), &PRE);
    fx.conn()
        .execute("DELETE FROM chunks WHERE id = ?", [cid(7)])
        .unwrap();
    fx.put_vec(&cid(8), &PRE);
    assert_eq!(fx.vec_ids(), sorted(&[1, 2, 7, 8]), "fixture");

    let table = TableEmbedder::new(DIM);
    let got = fx.run(&table, Some(&a), 2, 3).unwrap();

    assert_eq!(
        got,
        EmbedMissing {
            embedded: 0,
            pending: 0
        }
    );
    assert_eq!(table.calls(), 0);
    assert_eq!(
        fx.vec_ids(),
        sorted(&[1, 2]),
        "both orphans deleted; live vectors kept"
    );
    assert_eq!(fx.vec_of(&cid(1)), Some(PRE.to_vec()));
    assert_eq!(fx.vec_of(&cid(2)), Some(PRE.to_vec()));

    // Again with nothing picked (caps 0) while a chunk is unembedded.
    fx.chunk(&cid(3), &a, 3);
    fx.put_vec(&cid(9), &PRE);
    let got = fx.run(&table, Some(&a), 0, 0).unwrap();
    assert_eq!(
        got,
        EmbedMissing {
            embedded: 0,
            pending: 1
        }
    );
    assert_eq!(table.calls(), 0);
    assert_eq!(fx.vec_ids(), sorted(&[1, 2]), "the new orphan deleted too");
}

#[test]
fn a_run_that_embeds_also_deletes_orphan_vectors() {
    let Seeded { mut fx, a } = seeded();
    fx.put_vec(&cid(99), &PRE);
    fx.put_vec(&cid(98), &PRE);
    let table = table_for(&fx);

    let got = fx.run(&table, Some(&a), 1, 1).unwrap();

    assert_eq!(
        got,
        EmbedMissing {
            embedded: 2,
            pending: 7
        }
    );
    assert_eq!(fx.vec_ids(), sorted(&[50, 5, 40, 2]), "orphans 98, 99 gone");
}

// ---------------------------------------------------------------- AC 4

#[test]
fn creates_chunk_vec_with_the_embedder_dimension_when_absent() {
    let mut fx = new_vault();
    let a = fx.note("No vectors yet");
    fx.chunk(&cid(1), &a, 0);
    fx.chunk(&cid(2), &a, 1);
    assert!(!fx.has_chunk_vec(), "fixture: a vault without chunk_vec");
    let table = TableEmbedder::new(3)
        .with(text(&cid(1)), vec![1.0, 2.0, 3.0])
        .with(text(&cid(2)), vec![3.0, 2.0, 1.0]);

    let got = fx.run(&table, None, 0, 10).unwrap();

    let sql = chunk_vec_sql(fx.conn()).expect("chunk_vec created");
    assert!(
        sql.contains("float[3]"),
        "chunk_vec has the embedder's dimension 3: {sql}"
    );
    assert_eq!(
        got,
        EmbedMissing {
            embedded: 2,
            pending: 0
        }
    );
    assert_eq!(fx.vec_of(&cid(1)), Some(vec![1.0, 2.0, 3.0]));
    assert_eq!(fx.vec_of(&cid(2)), Some(vec![3.0, 2.0, 1.0]));
}

#[test]
fn creates_chunk_vec_even_when_nothing_is_picked() {
    let mut fx = new_vault();
    assert!(!fx.has_chunk_vec(), "fixture: a vault without chunk_vec");
    let table = TableEmbedder::new(5);

    let got = fx.run(&table, None, 10, 10).unwrap();

    let sql = chunk_vec_sql(fx.conn()).expect("chunk_vec created on an empty vault");
    assert!(sql.contains("float[5]"), "embedder dimension 5: {sql}");
    assert_eq!(
        got,
        EmbedMissing {
            embedded: 0,
            pending: 0
        }
    );
    assert_eq!(table.calls(), 0);
}

// ---------------------------------------------------------------- AC 5

#[test]
fn another_connections_write_commits_while_the_embedder_holds_a_batch() {
    let mut fx = three_unembedded();
    let gated = GatedEmbedder::new(table_for(&fx));
    let other = fx.other_writer();
    let note_b: String = fx
        .conn()
        .query_row("SELECT id FROM notes WHERE title = 'Gate B'", [], |r| {
            r.get(0)
        })
        .unwrap();
    let mut conn = fx.vault.connection_mut();

    let got = std::thread::scope(|s| {
        let _release = ReleaseOnDrop(&gated);
        let run = s.spawn(|| {
            let _release = ReleaseOnDrop(&gated);
            embed_missing(&mut conn, &gated, None, 0, 10)
        });

        assert!(
            gated.wait_entered(),
            "embed_missing returned without calling the embedder"
        );
        // busy_timeout 0: any write lock still held fails here at once.
        other
            .execute_batch("BEGIN IMMEDIATE")
            .expect("write transaction begins while the embedder holds the batch");
        other
            .execute(
                "UPDATE notes SET title = 'Renamed mid-embed' WHERE id = ?",
                [&note_b],
            )
            .expect("write while the embedder holds the batch");
        other
            .execute_batch("COMMIT")
            .expect("commit while the embedder holds the batch");
        gated.release();
        run.join().unwrap()
    })
    .unwrap();

    assert_eq!(
        got,
        EmbedMissing {
            embedded: 3,
            pending: 0
        }
    );
    assert_table_vectors(&fx, &[1, 2, 3]);
    let title: String = fx
        .conn()
        .query_row("SELECT title FROM notes WHERE id = ?", [&note_b], |r| {
            r.get(0)
        })
        .unwrap();
    assert_eq!(
        title, "Renamed mid-embed",
        "the other writer's commit stands"
    );
}

// ---------------------------------------------------------------- AC 6

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
fn into_shared(fx: Fx) -> (tempfile::TempDir, Mutex<Connection>) {
    let Fx { _dir, db, vault } = fx;
    drop(vault);
    let c = Connection::open(&db).unwrap();
    c.busy_timeout(Duration::from_secs(5)).unwrap();
    (_dir, Mutex::new(c))
}

#[test]
fn mutex_lease_is_free_while_the_embedder_holds_and_taken_once_per_insert() {
    let fx = three_unembedded();
    let gated = GatedEmbedder::new(table_for(&fx));
    let (_dir, shared) = into_shared(fx);

    let (got, leases) = std::thread::scope(|s| {
        let _release = ReleaseOnDrop(&gated);
        let run = s.spawn(|| {
            let _release = ReleaseOnDrop(&gated);
            let mut lease = MutexLease {
                conn: &shared,
                leases: 0,
            };
            let got = embed_missing(&mut lease, &gated, None, 0, 10);
            (got, lease.leases)
        });

        assert!(
            gated.wait_entered(),
            "embed_missing returned without calling the embedder"
        );
        {
            let guard = shared
                .try_lock()
                .expect("the vault mutex is free while the embedder holds the batch");
            guard
                .execute(
                    "UPDATE notes SET title = 'Taken mid-embed' WHERE title = 'Gate A'",
                    [],
                )
                .expect("another thread writes through the free mutex");
        }
        gated.release();
        run.join().unwrap()
    });

    let got = got.unwrap();
    assert_eq!(
        got,
        EmbedMissing {
            embedded: 3,
            pending: 0
        }
    );
    assert_eq!(
        leases,
        1 + 3,
        "one lease for the read phase, one per vector insert"
    );
    let conn = shared.lock().unwrap();
    for n in [1, 2, 3] {
        assert_eq!(vec_of(&conn, &cid(n)), Some(vec_for(&cid(n))));
    }
    let renamed: i64 = conn
        .query_row(
            "SELECT COUNT(*) FROM notes WHERE title = 'Taken mid-embed'",
            [],
            |r| r.get(0),
        )
        .unwrap();
    assert_eq!(renamed, 1, "the mid-embed write stands");
}

#[test]
fn mutex_lease_is_taken_once_when_nothing_is_picked() {
    let mut fx = new_vault();
    let a = fx.note("All embedded");
    fx.chunk(&cid(1), &a, 0);
    fx.put_vec(&cid(1), &PRE);
    fx.put_vec(&cid(2), &PRE); // an orphan, so the read phase has work
    let table = TableEmbedder::new(DIM);
    let (_dir, shared) = into_shared(fx);

    let mut lease = MutexLease {
        conn: &shared,
        leases: 0,
    };
    let got = embed_missing(&mut lease, &table, Some(&a), 10, 10).unwrap();

    assert_eq!(
        got,
        EmbedMissing {
            embedded: 0,
            pending: 0
        }
    );
    assert_eq!(lease.leases, 1, "the read phase only");
    assert_eq!(table.calls(), 0);
    let conn = shared.lock().unwrap();
    assert_eq!(vec_of(&conn, &cid(2)), None, "orphan deleted in that lease");
}

// ---------------------------------------------------------------- AC 7

#[test]
fn chunk_deleted_while_the_embedder_holds_gets_no_vector() {
    let mut fx = three_unembedded();
    let gated = GatedEmbedder::new(table_for(&fx));
    let other = fx.other_writer();
    let mut conn = fx.vault.connection_mut();

    let got = std::thread::scope(|s| {
        let _release = ReleaseOnDrop(&gated);
        let run = s.spawn(|| {
            let _release = ReleaseOnDrop(&gated);
            embed_missing(&mut conn, &gated, None, 0, 10)
        });

        assert!(
            gated.wait_entered(),
            "embed_missing returned without calling the embedder"
        );
        // The first picked chunk (lowest id) goes away mid-embed.
        other
            .execute("DELETE FROM chunks WHERE id = ?", [cid(1)])
            .expect("delete while the embedder holds the batch");
        gated.release();
        run.join().unwrap()
    })
    .expect("a chunk deleted mid-embed does not fail the run");

    assert_eq!(fx.vec_of(&cid(1)), None, "no vector (and no orphan) for it");
    assert_eq!(fx.vec_ids(), sorted(&[2, 3]), "the rest still inserted");
    assert_table_vectors(&fx, &[2, 3]);
    assert_eq!(
        got,
        EmbedMissing {
            embedded: 2,
            pending: 0
        },
        "embedded counts the vectors written"
    );
    assert_eq!(got.pending, fx.remainder());
}

// ---------------------------------------------------------------- AC 8

#[test]
fn chunk_given_a_vector_by_another_writer_while_held_keeps_it() {
    let mut fx = three_unembedded();
    let gated = GatedEmbedder::new(table_for(&fx));
    let other = fx.other_writer();
    let theirs = [9.0, 9.0, 9.0, 9.0];
    let mut conn = fx.vault.connection_mut();

    let got = std::thread::scope(|s| {
        let _release = ReleaseOnDrop(&gated);
        let run = s.spawn(|| {
            let _release = ReleaseOnDrop(&gated);
            embed_missing(&mut conn, &gated, None, 0, 10)
        });

        assert!(
            gated.wait_entered(),
            "embed_missing returned without calling the embedder"
        );
        // Another writer embeds the first picked chunk first.
        other
            .execute(
                "INSERT INTO chunk_vec (chunk_id, embedding) VALUES (?, ?)",
                params![cid(1), le_bytes(&theirs)],
            )
            .expect("vector insert while the embedder holds the batch");
        gated.release();
        run.join().unwrap()
    })
    .expect("a conflicting vector is skipped, never an error");

    assert_eq!(
        fx.vec_of(&cid(1)),
        Some(theirs.to_vec()),
        "the other writer's vector is kept"
    );
    assert_table_vectors(&fx, &[2, 3]);
    assert_eq!(
        got,
        EmbedMissing {
            embedded: 2,
            pending: 0
        },
        "the skipped chunk is not counted as embedded"
    );
}

// ---------------------------------------------------------------- AC 9

#[test]
fn chunks_table_is_identical_before_and_after_a_run() {
    let mut fx = new_vault();
    let a = fx.note("Models");
    let b = fx.note("Other models");
    fx.chunk_with_model(&cid(1), &a, 0, Some("old-model-v0"));
    fx.chunk_with_model(&cid(2), &a, 1, None);
    fx.chunk_with_model(&cid(3), &b, 0, Some("BAAI/bge-small-en-v1.5"));
    fx.chunk_with_model(&cid(4), &b, 1, None);
    let table = table_for(&fx);
    let before = fx.chunks_snapshot();

    let got = fx.run(&table, Some(&a), 10, 10).unwrap();

    assert_eq!(got.embedded, 4, "the run did embed every chunk");
    assert_table_vectors(&fx, &[1, 2, 3, 4]);
    assert_eq!(
        fx.chunks_snapshot(),
        before,
        "chunks, embed_model_version included, unchanged"
    );
    assert!(
        before
            .iter()
            .all(|r| r.embed_model_version.as_deref() != Some("table-v1")),
        "fixture: no chunk carries the embedder's model version"
    );
}

// ---------------------------------------------------------------- AC 10

#[test]
fn inserting_vectors_leaves_content_revision_unchanged() {
    let Seeded { mut fx, a } = seeded();
    fx.put_vec(&cid(97), &PRE); // an orphan the run deletes
    let table = table_for(&fx);
    let n = fx.revision();

    let got = fx.run(&table, Some(&a), 4, 5).unwrap();

    assert_eq!(got.embedded, 9, "the run inserted 9 vectors");
    assert_eq!(fx.vec_of(&cid(97)), None, "and deleted the orphan");
    assert_eq!(
        fx.revision(),
        n,
        "vector inserts and orphan deletes leave content_revision.n alone"
    );
    // Control: the revision triggers are live on this vault.
    fx.conn()
        .execute("UPDATE notes SET title = 'Moved' WHERE id = ?", [&a])
        .unwrap();
    assert!(fx.revision() > n, "an ordinary write moves n");
}

#[test]
fn creating_chunk_vec_and_inserting_leaves_content_revision_unchanged() {
    let mut fx = new_vault();
    let a = fx.note("Fresh");
    fx.chunk(&cid(1), &a, 0);
    fx.chunk(&cid(2), &a, 1);
    assert!(!fx.has_chunk_vec(), "fixture: no chunk_vec yet");
    let table = table_for(&fx);
    let n = fx.revision();

    let got = fx.run(&table, None, 0, 10).unwrap();

    assert_eq!(got.embedded, 2);
    assert!(fx.has_chunk_vec());
    assert_eq!(
        fx.revision(),
        n,
        "creating chunk_vec and inserting into it leave n alone"
    );
}

// ---------------------------------------------------------------- AC 11

#[test]
fn nothing_unembedded_never_calls_the_embedder() {
    let mut fx = new_vault();
    let a = fx.note("Lazy");
    fx.chunk(&cid(1), &a, 0);
    fx.chunk(&cid(2), &a, 1);
    let table = table_for(&fx);

    let first = fx.run(&table, Some(&a), 10, 10).unwrap();
    assert_eq!(first.embedded, 2, "first run embeds both chunks");
    let calls = table.calls();
    assert!(calls >= 1, "first run called the embedder");

    let second = fx.run(&table, Some(&a), 10, 10).unwrap();
    assert_eq!(
        second,
        EmbedMissing {
            embedded: 0,
            pending: 0
        }
    );
    assert_eq!(
        table.calls(),
        calls,
        "nothing unembedded: the embedder is not called again"
    );

    let gated = GatedEmbedder::new(TableEmbedder::new(DIM));
    let third = fx.run(&gated, None, 10, 10).unwrap();
    assert_eq!(third.embedded, 0);
    assert_eq!(gated.calls(), 0, "a closed gate is never reached");
}

// ---------------------------------------------------------------- contracts

/// An embedder failure is returned (echoes maps it to
/// `embedder_unavailable`, req 17), and no vector is written.
#[test]
fn embedder_error_is_returned_and_writes_no_vector() {
    let mut fx = new_vault();
    let a = fx.note("Unknown text");
    fx.chunk(&cid(1), &a, 0);
    let table = TableEmbedder::new(DIM); // knows no text: every batch errors

    let err = fx.run(&table, None, 0, 10).unwrap_err();

    assert!(
        matches!(err, MemexError::EmbedderInfer(_)),
        "the embedder's error comes back: {err:?}"
    );
    assert_eq!(table.calls(), 1);
    assert!(fx.has_chunk_vec(), "the read phase still created chunk_vec");
    assert!(fx.vec_ids().is_empty(), "no vector written");
}

// ---------------------------------------------------------------- test doubles

#[test]
fn table_embedder_returns_exact_vectors_and_counts_batches() {
    let mut t = TableEmbedder::new(2)
        .with("a", vec![1.0, 0.0])
        .with("b", vec![0.0, 1.0]);
    assert_eq!(t.dimension(), 2);
    assert_eq!(t.model_version(), "table-v1");
    assert_eq!(t.calls(), 0);

    let got = t.embed_batch(&["b".to_string(), "a".to_string()]).unwrap();
    assert_eq!(got, vec![vec![0.0, 1.0], vec![1.0, 0.0]], "in input order");
    assert_eq!(t.calls(), 1, "one call per batch, not per text");

    assert!(t.embed_batch(&[]).unwrap().is_empty());
    assert_eq!(t.calls(), 2, "an empty batch is still a call");

    t.insert("a", vec![0.5, 0.5]);
    assert_eq!(
        t.embed_batch(&["a".to_string()]).unwrap(),
        vec![vec![0.5, 0.5]],
        "insert replaces"
    );
}

#[test]
fn table_embedder_errors_on_unknown_text() {
    let t = TableEmbedder::new(2).with("known", vec![1.0, 0.0]);
    let err = t
        .embed_batch(&["known".to_string(), "unknown".to_string()])
        .unwrap_err();
    match err {
        MemexError::EmbedderInfer(m) => assert!(m.contains("unknown"), "names the text: {m}"),
        other => panic!("expected EmbedderInfer, got {other:?}"),
    }
    assert_eq!(t.calls(), 1, "a failing batch is counted");
}

#[test]
fn gated_embedder_holds_until_released() {
    let gated = GatedEmbedder::new(TableEmbedder::new(2).with("x", vec![1.0, 2.0]));
    assert_eq!(gated.dimension(), 2);
    assert_eq!(gated.model_version(), "table-v1");
    assert_eq!(gated.calls(), 0);

    let got = std::thread::scope(|s| {
        let _release = ReleaseOnDrop(&gated);
        let call = s.spawn(|| gated.embed_batch(&["x".to_string()]));
        assert!(gated.wait_entered(), "the call is held at the gate");
        assert_eq!(gated.calls(), 1);
        assert!(gated.wait_entered(), "still held until released");
        gated.release();
        call.join().unwrap()
    });
    assert_eq!(got.unwrap(), vec![vec![1.0, 2.0]], "answers with inner");
    assert!(
        !gated.wait_entered(),
        "released and nothing held: wait_entered returns false"
    );

    // The gate stays open: a later call passes straight through.
    assert_eq!(
        gated.embed_batch(&["x".to_string()]).unwrap(),
        vec![vec![1.0, 2.0]]
    );
    assert_eq!(gated.calls(), 2);
    assert!(
        gated.embed_batch(&["y".to_string()]).is_err(),
        "inner errors pass through"
    );
}

#[test]
fn gated_embedder_wait_entered_is_false_once_released_unused() {
    let gated = GatedEmbedder::new(TableEmbedder::new(2));
    gated.release();
    assert!(!gated.wait_entered());
    assert_eq!(gated.calls(), 0);
}

// ---------------------------------------------------------------- verify: pinned contracts

/// Caps above `i64::MAX` (`usize::MAX`) must act as "no cap", not as 0 or an
/// SQL error.
#[test]
fn usize_max_caps_embed_everything() {
    let Seeded { mut fx, a } = seeded();
    let table = table_for(&fx);

    let got = fx.run(&table, Some(&a), usize::MAX, usize::MAX).unwrap();

    assert_eq!(
        got,
        EmbedMissing {
            embedded: 9,
            pending: 0
        }
    );
    assert_table_vectors(&fx, &[40, 30, 1, 20, 2, 3, 9, 12, 15]);
}

/// An embedder double that answers `delta` vectors more (or fewer, when
/// negative) than the texts it was given.
struct WrongCountEmbedder {
    delta: isize,
}

impl Embedder for WrongCountEmbedder {
    fn model_version(&self) -> &str {
        "wrong-count"
    }

    fn dimension(&self) -> usize {
        DIM
    }

    fn embed_batch(&self, texts: &[String]) -> Result<Vec<Vec<f32>>> {
        let n = (texts.len() as isize + self.delta) as usize;
        Ok(vec![vec![1.0; DIM]; n])
    }
}

/// A batch answered with the wrong number of vectors would pair vectors with
/// the wrong chunks: it is an `EmbedderInfer` error and writes nothing.
#[test]
fn a_vector_count_that_does_not_match_the_texts_is_an_error_and_writes_nothing() {
    for (name, delta) in [("one short", -1isize), ("one extra", 1), ("empty", -3)] {
        let mut fx = three_unembedded();

        let err = fx
            .run(&WrongCountEmbedder { delta }, None, 0, 10)
            .unwrap_err();

        match err {
            MemexError::EmbedderInfer(m) => {
                assert!(m.contains("vectors") && m.contains("texts"), "{name}: {m}")
            }
            other => panic!("{name}: expected EmbedderInfer, got {other:?}"),
        }
        assert!(fx.vec_ids().is_empty(), "{name}: no vector written");
        assert_eq!(fx.remainder(), 3, "{name}: nothing embedded");
    }
}

/// The exact count passes the guard.
#[test]
fn a_matching_vector_count_is_accepted() {
    let mut fx = three_unembedded();

    let got = fx
        .run(&WrongCountEmbedder { delta: 0 }, None, 0, 10)
        .unwrap();

    assert_eq!(
        got,
        EmbedMissing {
            embedded: 3,
            pending: 0
        }
    );
}

// ---------------------------------------------------------------- verify r1: partial failure

/// A lease over the vault's own connection that fails its `fail_on`-th call
/// (1-based) without running the closure, as V3's server lock could.
struct FailingLease<'a> {
    conn: &'a mut Connection,
    calls: usize,
    fail_on: usize,
}

impl ConnLease for FailingLease<'_> {
    fn lease<R>(&mut self, f: impl FnOnce(&mut Connection) -> Result<R>) -> Result<R> {
        self.calls += 1;
        if self.calls == self.fail_on {
            return Err(MemexError::EmbedderInfer("lease refused".to_string()));
        }
        f(self.conn)
    }
}

/// Each vector commits in its own lease: when insert k fails, vectors 0..k-1
/// stay with their exact bytes, nothing after k is written, the run is an
/// error, and a rerun embeds the rest.
#[test]
fn a_lease_failing_mid_run_keeps_earlier_vectors_and_a_rerun_finishes() {
    let mut fx = three_unembedded();
    let table = table_for(&fx);

    // Call 1 is the read phase, call 2 the first insert, call 3 the second.
    let err = {
        let mut lease = FailingLease {
            conn: fx.vault.connection_mut(),
            calls: 0,
            fail_on: 3,
        };
        let err = embed_missing(&mut lease, &table, None, 0, 10).unwrap_err();
        assert_eq!(lease.calls, 3, "the run stops at the failed lease");
        err
    };

    assert!(
        matches!(&err, MemexError::EmbedderInfer(m) if m == "lease refused"),
        "the lease error is returned as is, got {err:?}"
    );
    assert_eq!(
        fx.vec_ids(),
        vec![cid(1)],
        "only the insert before the failure is kept"
    );
    assert_eq!(fx.vec_of(&cid(1)), Some(vec_for(&cid(1))));
    assert_eq!(fx.remainder(), 2);

    let got = fx.run(&table, None, 0, 10).unwrap();
    assert_eq!(
        got,
        EmbedMissing {
            embedded: 2,
            pending: 0
        }
    );
    assert_table_vectors(&fx, &[1, 2, 3]);
}

/// Answers every text with a `DIM`-wide vector except the one at `bad_index`,
/// which is one element too long (a vec0 dimension mismatch on insert).
struct OneBadVectorEmbedder {
    bad_index: usize,
}

impl Embedder for OneBadVectorEmbedder {
    fn model_version(&self) -> &str {
        "one-bad-vector"
    }

    fn dimension(&self) -> usize {
        DIM
    }

    fn embed_batch(&self, texts: &[String]) -> Result<Vec<Vec<f32>>> {
        Ok((0..texts.len())
            .map(|i| {
                let width = if i == self.bad_index { DIM + 1 } else { DIM };
                vec![0.25; width]
            })
            .collect())
    }
}

/// A vec0 dimension mismatch on the 2nd insert is an error (never swallowed
/// into a short `Ok`); the 1st vector stays, the 3rd is never written, and a
/// rerun with a good embedder finishes the rest.
#[test]
fn a_dimension_mismatch_on_a_later_insert_errors_keeps_earlier_vectors_and_a_rerun_finishes() {
    let mut fx = three_unembedded();

    let err = fx
        .run(&OneBadVectorEmbedder { bad_index: 1 }, None, 0, 10)
        .unwrap_err();

    assert!(
        matches!(err, MemexError::Sqlite(_)),
        "the insert failure is returned, got {err:?}"
    );
    assert_eq!(
        fx.vec_ids(),
        vec![cid(1)],
        "the earlier insert is kept, the later ones are not written"
    );
    assert_eq!(fx.vec_of(&cid(1)), Some(vec![0.25; DIM]));
    assert_eq!(fx.remainder(), 2);

    let table = table_for(&fx);
    let got = fx.run(&table, None, 0, 10).unwrap();
    assert_eq!(
        got,
        EmbedMissing {
            embedded: 2,
            pending: 0
        }
    );
    assert_eq!(
        fx.vec_of(&cid(1)),
        Some(vec![0.25; DIM]),
        "the rerun does not touch the kept vector"
    );
    assert_eq!(fx.vec_of(&cid(2)), Some(vec_for(&cid(2))));
    assert_eq!(fx.vec_of(&cid(3)), Some(vec_for(&cid(3))));
}
