//! #421 (Spec #391 requirements 11-16): `echoes::echoes` finds passages in
//! other, unlinked notes that are close to the open note, one per note, and
//! picks the best block of each winning chunk as its passage.
//!
//! Vectors are written straight into `chunk_vec` (8-d, chosen per test) so
//! similarities are exact, and the embedder is a [`TableEmbedder`]: a text it
//! has no entry for is an error, so a test whose table is empty also proves
//! the read embedded nothing. Real SQLite with sqlite-vec, temp vaults only.
//!
//! Query vector `Q` is axis 0. `near(0, side, s)` has cosine `s` to `Q`.

use std::sync::Mutex;
use std::time::Duration;

use memex_core::echoes::{echoes, Echo, Echoes, ECHO_MIN_SIMILARITY};
use memex_core::embedder::{Embedder, GatedEmbedder, TableEmbedder};
use memex_core::footer::{self, ChipOrigin};
use memex_core::guide;
use memex_core::indexer;
use memex_core::notes::{create_note_as, CreateNote, NoteId};
use memex_core::schema;
use memex_core::vectors::{embedding_counts, ConnLease};
use memex_core::{Caller, MemexError, Result, SystemClock, Vault};
use rusqlite::{params, Connection, OptionalExtension};
use serde_json::{json, Value};

const DIM: usize = 8;
const LIMIT: usize = 8;

// ---------------------------------------------------------------- vectors

/// The unit vector on `axis`.
fn e(axis: usize) -> Vec<f32> {
    let mut v = vec![0.0; DIM];
    v[axis] = 1.0;
    v
}

/// A unit vector with cosine `s` to `e(axis)`, the rest on `e(side)`.
fn near(axis: usize, side: usize, s: f32) -> Vec<f32> {
    assert_ne!(axis, side);
    let mut v = vec![0.0; DIM];
    v[axis] = s;
    v[side] = (1.0 - s * s).sqrt();
    v
}

/// The query vector most tests give the open note.
fn q() -> Vec<f32> {
    e(0)
}

/// Norm exactly 10 with 7 on axis 0: its cosine to `Q` computes to exactly
/// `0.7f32` (`7 / (1 * 10)`), so `1 - distance` is the threshold itself.
fn exactly_threshold() -> Vec<f32> {
    vec![7.0, 0.0, 7.0, 0.0, 1.0, 1.0, 0.0, 0.0]
}

fn le_bytes(v: &[f32]) -> Vec<u8> {
    v.iter().flat_map(|f| f.to_le_bytes()).collect()
}

// ---------------------------------------------------------------- bodies

/// `n` filler words.
fn filler(n: usize) -> String {
    const WORDS: [&str; 5] = ["lorem", "ipsum", "dolor", "sit", "amet"];
    (0..n)
        .map(|i| WORDS[i % WORDS.len()])
        .collect::<Vec<_>>()
        .join(" ")
}

/// A block big enough (about 400 tokens) to be a chunk of its own.
fn big_block(tag: &str) -> String {
    format!("{tag} {}", filler(300))
}

/// A daily body of three blocks, each its own chunk, with multibyte text
/// before every block.
fn long_day_body() -> String {
    format!(
        "{}\n\n{}\n\n{}\n",
        big_block("Café ☕ fixed the jump arc."),
        big_block("Naïve 🎉 tried coyote time."),
        big_block("Zoë 😀 sleep was bad."),
    )
}

const DAY_BLOCK_IDS: [&str; 3] = ["b7k2m9", "c3d4e5", "f6g7h8"];

// ---------------------------------------------------------------- fixture

struct Fx {
    _dir: tempfile::TempDir,
    db: std::path::PathBuf,
    vault: Vault,
}

#[derive(Debug, Clone)]
struct ChunkRow {
    id: String,
    content: String,
    start_byte: Option<i64>,
}

fn new_vault() -> Fx {
    let dir = tempfile::tempdir().unwrap();
    let vault = Vault::create(dir.path()).unwrap();
    schema::ensure_vector_table(vault.connection_ref(), DIM).unwrap();
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

    /// Creates a note as the person and indexes it with no embedder.
    fn create(&mut self, title: &str, body: &str, fm: Option<Value>) -> String {
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
            None,
        )
        .unwrap();
        note.id.as_str().to_string()
    }

    fn plain(&mut self, title: &str, body: &str) -> String {
        self.create(title, body, None)
    }

    fn topic(&mut self, title: &str, body: &str) -> String {
        self.create(title, body, Some(json!({ "role": "topic" })))
    }

    fn daily(&mut self, date: &str, body: &str) -> String {
        self.create(date, body, Some(json!({ "role": "daily" })))
    }

    /// A plain note with a chosen id and `updated_at`, indexed with no
    /// embedder (for the `note_id` and `updated_at` tie-breaks).
    fn note_with_id(&mut self, id: &str, title: &str, body: &str, updated_at: i64) -> String {
        self.conn()
            .execute(
                "INSERT INTO notes (id, title, content_md, frontmatter, version, created_at,
                                    updated_at)
                 VALUES (?, ?, ?, '{}', 1, ?, ?)",
                params![id, title, body, updated_at, updated_at],
            )
            .unwrap();
        indexer::reindex_note(self.vault.connection_mut(), id, body, None).unwrap();
        id.to_string()
    }

    /// The Vault Guide, created on first read.
    fn guide(&mut self) -> String {
        guide::get_or_create(&mut self.vault, &SystemClock, None)
            .unwrap()
            .note_id
    }

    fn body(&self, note: &str) -> String {
        self.conn()
            .query_row("SELECT content_md FROM notes WHERE id = ?", [note], |r| {
                r.get(0)
            })
            .unwrap()
    }

    fn updated_at(&self, note: &str) -> i64 {
        self.conn()
            .query_row("SELECT updated_at FROM notes WHERE id = ?", [note], |r| {
                r.get(0)
            })
            .unwrap()
    }

    fn set_updated_at(&self, note: &str, ms: i64) {
        let n = self
            .conn()
            .execute(
                "UPDATE notes SET updated_at = ? WHERE id = ?",
                params![ms, note],
            )
            .unwrap();
        assert_eq!(n, 1);
    }

    fn chunks(&self, note: &str) -> Vec<ChunkRow> {
        let mut stmt = self
            .conn()
            .prepare("SELECT id, content, start_byte FROM chunks WHERE note_id = ? ORDER BY ord")
            .unwrap();
        stmt.query_map([note], |r| {
            Ok(ChunkRow {
                id: r.get(0)?,
                content: r.get(1)?,
                start_byte: r.get(2)?,
            })
        })
        .unwrap()
        .map(|r| r.unwrap())
        .collect()
    }

    fn put_vec(&self, chunk_id: &str, v: &[f32]) {
        self.conn()
            .execute(
                "INSERT INTO chunk_vec (chunk_id, embedding) VALUES (?, ?)",
                params![chunk_id, le_bytes(v)],
            )
            .unwrap();
    }

    /// Gives every chunk of `note` the vector `v`.
    fn embed(&self, note: &str, v: &[f32]) {
        let chunks = self.chunks(note);
        assert!(!chunks.is_empty(), "precondition: note {note} has chunks");
        for c in chunks {
            self.put_vec(&c.id, v);
        }
    }

    /// Gives each chunk of `note` (by `ord`) its own vector.
    fn embed_each(&self, note: &str, vs: &[Vec<f32>]) {
        let chunks = self.chunks(note);
        assert_eq!(
            chunks.len(),
            vs.len(),
            "precondition: chunk count of {note}"
        );
        for (c, v) in chunks.iter().zip(vs) {
            self.put_vec(&c.id, v);
        }
    }

    /// Inserts a chunk row by hand; `v` (if any) becomes its vector.
    fn raw_chunk(&self, id: &str, note: &str, ord: i64, content: &str, v: Option<&[f32]>) {
        self.conn()
            .execute(
                "INSERT INTO chunks
                    (id, note_id, ord, content, token_count, embed_model_version,
                     start_byte, end_byte)
                 VALUES (?, ?, ?, ?, 3, NULL, NULL, NULL)",
                params![id, note, ord, content],
            )
            .unwrap();
        if let Some(v) = v {
            self.put_vec(id, v);
        }
    }

    /// Drops every chunk (and vector) of `note`.
    fn clear_chunks(&self, note: &str) {
        for c in self.chunks(note) {
            self.conn()
                .execute("DELETE FROM chunk_vec WHERE chunk_id = ?", [&c.id])
                .unwrap();
        }
        self.conn()
            .execute("DELETE FROM chunks WHERE note_id = ?", [note])
            .unwrap();
    }

    /// `(to_note_id, link_kind)` of `from`'s link with text `text`.
    fn link(&self, from: &str, text: &str) -> (Option<String>, String) {
        self.conn()
            .query_row(
                "SELECT to_note_id, link_kind FROM links WHERE from_note_id = ? AND link_text = ?",
                params![from, text],
                |r| Ok((r.get(0)?, r.get(1)?)),
            )
            .optional()
            .unwrap()
            .unwrap_or_else(|| panic!("precondition: {from} has a link to {text:?}"))
    }

    /// Pins the block ids of a three-block daily note.
    fn pin_day_blocks(&self, day: &str) {
        for (ord, id) in DAY_BLOCK_IDS.iter().enumerate() {
            let n = self
                .conn()
                .execute(
                    "UPDATE blocks SET block_id = ? WHERE note_id = ? AND ord = ?",
                    params![id, day, ord as i64],
                )
                .unwrap();
            assert_eq!(n, 1, "precondition: day block {ord}");
        }
    }

    fn try_run(
        &mut self,
        embedder: &dyn Embedder,
        note: &str,
        limit: usize,
        others_cap: usize,
    ) -> Result<Echoes> {
        let mut conn = self.vault.connection_mut();
        echoes(&mut conn, embedder, note, limit, others_cap)
    }

    /// A read of a vault whose chunks all have vectors already.
    fn run(&mut self, embedder: &dyn Embedder, note: &str, limit: usize) -> Echoes {
        let c = embedding_counts(self.conn()).unwrap();
        assert_eq!(
            c.embedded, c.chunks,
            "precondition: every chunk is embedded"
        );
        self.try_run(embedder, note, limit, 64)
            .unwrap_or_else(|e| panic!("echoes of {note}: {e}"))
    }

    /// A read with an empty table embedder: any embed call fails it.
    fn run_unembedded(&mut self, note: &str) -> Echoes {
        self.run(&no_embedding(), note, LIMIT)
    }
}

/// A table embedder that knows no text: any `embed_batch` with a text errs.
fn no_embedding() -> TableEmbedder {
    TableEmbedder::new(DIM)
}

fn ids(got: &Echoes) -> Vec<String> {
    got.echoes.iter().map(|e| e.note_id.clone()).collect()
}

fn names(fx: &Fx, got: &Echoes) -> Vec<String> {
    got.echoes
        .iter()
        .map(|e| {
            fx.conn()
                .query_row("SELECT title FROM notes WHERE id = ?", [&e.note_id], |r| {
                    r.get(0)
                })
                .unwrap()
        })
        .collect()
}

fn the_echo<'a>(got: &'a Echoes, note: &str) -> &'a Echo {
    got.echoes
        .iter()
        .find(|e| e.note_id == note)
        .unwrap_or_else(|| panic!("no echo from {note}: {got:?}"))
}

/// An open note whose one chunk has vector `Q`.
fn open_plain(fx: &mut Fx, title: &str) -> String {
    let o = fx.plain(title, "The open note is about lighthouse keepers.");
    fx.embed(&o, &q());
    o
}

/// Records every `embed_batch` call's texts, answering from a table.
struct Recording {
    table: TableEmbedder,
    batches: Mutex<Vec<Vec<String>>>,
}

impl Recording {
    fn new(table: TableEmbedder) -> Self {
        Self {
            table,
            batches: Mutex::new(Vec::new()),
        }
    }

    fn batches(&self) -> Vec<Vec<String>> {
        self.batches.lock().unwrap().clone()
    }
}

impl Embedder for Recording {
    fn model_version(&self) -> &str {
        self.table.model_version()
    }

    fn dimension(&self) -> usize {
        self.table.dimension()
    }

    fn embed_batch(&self, texts: &[String]) -> Result<Vec<Vec<f32>>> {
        self.batches.lock().unwrap().push(texts.to_vec());
        self.table.embed_batch(texts)
    }
}

// ---------------------------------------------------------------- SDK

/// sqlite-vec's cosine distance for `exactly_threshold()` against `Q` is
/// exactly `1 - 0.70f32`, which the threshold boundary test relies on.
#[test]
fn sqlite_vec_cosine_of_the_boundary_vector_is_exactly_the_threshold() {
    let fx = new_vault();
    fx.conn()
        .execute(
            "INSERT INTO chunk_vec (chunk_id, embedding) VALUES ('b', ?)",
            [le_bytes(&exactly_threshold())],
        )
        .unwrap();
    let d: f64 = fx
        .conn()
        .query_row(
            "SELECT distance FROM chunk_vec WHERE embedding MATCH ? AND k = 1 ORDER BY distance",
            [le_bytes(&q())],
            |r| r.get(0),
        )
        .unwrap();
    assert_eq!(1.0 - d as f32, ECHO_MIN_SIMILARITY);
    assert_eq!(1.0 - d, ECHO_MIN_SIMILARITY as f64);
}

// ---------------------------------------------------------------- AC 1: exclusions

#[test]
fn own_note_chunks_are_never_echoes() {
    let mut fx = new_vault();
    let body = format!(
        "{}\n\n{}",
        big_block("Own first."),
        big_block("Own second.")
    );
    let o = fx.plain("Open", &body);
    // The second own chunk is close to the first: a candidate if not excluded.
    fx.embed_each(&o, &[q(), near(0, 1, 0.95)]);
    let other = fx.plain("Other", "Another note about lighthouses.");
    fx.embed(&other, &near(0, 2, 0.9));

    let got = fx.run_unembedded(&o);

    assert_eq!(
        ids(&got),
        vec![other],
        "own chunks dropped; the other note kept"
    );
}

#[test]
fn the_vault_guide_is_never_an_echo() {
    let mut fx = new_vault();
    let o = open_plain(&mut fx, "Open");
    let g = fx.guide();
    fx.embed(&g, &near(0, 1, 0.95));
    let p = fx.plain("Plain", "A plain note.");
    fx.embed(&p, &near(0, 2, 0.9));

    let got = fx.run_unembedded(&o);

    assert_eq!(
        ids(&got),
        vec![p],
        "the guide is dropped; an equal plain note is kept"
    );
}

#[test]
fn notes_the_open_note_links_to_are_excluded_whatever_the_kind() {
    let mut fx = new_vault();
    let r = fx.plain("Ref Target", "Referenced.");
    let x = fx.plain("Ext Target", "Extended.");
    let c = fx.plain("Custom Target", "Inspired.");
    let a = fx.plain("Alias Target", "Aliased.");
    let o = fx.plain(
        "Open",
        "See [[Ref Target]], [[Ext Target~extends]], [[Custom Target~inspired-by]] \
         and [[Alias Target|the alias]].",
    );
    for (t, kind) in [
        ("Ref Target", "references"),
        ("Ext Target", "extends"),
        ("Custom Target", "inspired-by"),
        ("Alias Target", "references"),
    ] {
        let (to, k) = fx.link(&o, t);
        assert!(to.is_some(), "precondition: link to {t} is resolved");
        assert_eq!(k, kind, "precondition: link kind to {t}");
    }
    fx.embed(&o, &q());
    for (i, n) in [&r, &x, &c, &a].into_iter().enumerate() {
        fx.embed(n, &near(0, 1 + i, 0.95));
    }
    let u = fx.plain("Unlinked", "Not linked.");
    fx.embed(&u, &near(0, 6, 0.9));

    let got = fx.run_unembedded(&o);

    assert_eq!(
        ids(&got),
        vec![u],
        "every link target is dropped; the unlinked note kept"
    );
}

#[test]
fn notes_linking_to_the_open_note_are_excluded() {
    let mut fx = new_vault();
    let o = open_plain(&mut fx, "Open");
    let s1 = fx.plain("Source One", "Points at [[Open]].");
    let s2 = fx.plain("Source Two", "Argues with [[Open~contradicts]].");
    assert_eq!(fx.link(&s1, "Open").0.as_deref(), Some(o.as_str()));
    assert_eq!(fx.link(&s2, "Open").0.as_deref(), Some(o.as_str()));
    fx.embed(&s1, &near(0, 1, 0.95));
    fx.embed(&s2, &near(0, 2, 0.95));
    let u = fx.plain("Unlinked", "Points at [[Someone Else]].");
    fx.embed(&u, &near(0, 3, 0.9));

    let got = fx.run_unembedded(&o);

    assert_eq!(ids(&got), vec![u], "incoming links drop their source");
}

#[test]
fn a_filed_day_is_excluded_from_its_topic_by_its_about_chip() {
    let mut fx = new_vault();
    let t = fx.topic("Lighthouses", "The topic note about lighthouses.");
    let filed = fx.daily("2026-09-05", "Visited a lighthouse.");
    let unfiled = fx.daily("2026-09-06", "Saw another lighthouse.");
    footer::set_chip(
        &mut fx.vault,
        &NoteId::parse(&filed).unwrap(),
        &NoteId::parse(&t).unwrap(),
        ChipOrigin::Person,
        None,
    )
    .unwrap();
    let (to, kind) = fx.link(&filed, "Lighthouses");
    assert_eq!((to.as_deref(), kind.as_str()), (Some(t.as_str()), "about"));
    fx.embed(&t, &q());
    fx.embed(&filed, &near(0, 1, 0.95));
    fx.embed(&unfiled, &near(0, 2, 0.9));

    let got = fx.run_unembedded(&t);

    assert_eq!(
        ids(&got),
        vec![unfiled],
        "the filed day is dropped, the unfiled day kept"
    );
}

#[test]
fn a_daily_notes_about_chip_excludes_its_topic() {
    let mut fx = new_vault();
    let chipped = fx.topic("Lighthouses", "The topic note about lighthouses.");
    let other = fx.topic("Harbours", "The topic note about harbours.");
    let d = fx.daily("2026-09-05", "Visited a lighthouse.");
    footer::set_chip(
        &mut fx.vault,
        &NoteId::parse(&d).unwrap(),
        &NoteId::parse(&chipped).unwrap(),
        ChipOrigin::Person,
        None,
    )
    .unwrap();
    assert_eq!(fx.link(&d, "Lighthouses").1, "about");
    fx.embed(&d, &q());
    fx.embed(&chipped, &near(0, 1, 0.95));
    fx.embed(&other, &near(0, 2, 0.9));

    let got = fx.run_unembedded(&d);

    assert_eq!(
        ids(&got),
        vec![other],
        "the chipped topic is dropped, another topic kept"
    );
}

#[test]
fn a_topic_that_transcludes_the_open_day_is_excluded_by_its_from_day_link() {
    let mut fx = new_vault();
    let d = fx.daily("2026-09-05", &long_day_body());
    fx.pin_day_blocks(&d);
    let excerpting = fx.topic("Jumping", "Notes on jumping.\n\n![[2026-09-05#^c3d4e5]]\n");
    let (to, kind) = fx.link(&excerpting, "2026-09-05");
    assert_eq!(
        (to.as_deref(), kind.as_str()),
        (Some(d.as_str()), "from-day")
    );
    let other = fx.topic("Sleeping", "Notes on sleeping.");
    fx.embed(&d, &q());
    fx.embed(&excerpting, &near(0, 1, 0.95));
    fx.embed(&other, &near(0, 2, 0.9));

    let got = fx.run_unembedded(&d);

    assert_eq!(ids(&got), vec![other], "the excerpting topic is dropped");
}

#[test]
fn a_day_the_open_topic_transcludes_is_excluded_by_its_from_day_link() {
    let mut fx = new_vault();
    let d = fx.daily("2026-09-05", &long_day_body());
    fx.pin_day_blocks(&d);
    let other_day = fx.daily("2026-09-06", "A different day.");
    let t = fx.topic("Jumping", "Notes on jumping.\n\n![[2026-09-05#^c3d4e5]]\n");
    fx.embed(&t, &q());
    // The day's chunks are close to the topic's own query vector.
    fx.embed(&d, &near(0, 1, 0.95));
    fx.embed(&other_day, &near(0, 2, 0.9));

    let got = fx.run_unembedded(&t);

    assert_eq!(ids(&got), vec![other_day], "the transcluded day is dropped");
}

#[test]
fn an_unresolved_outgoing_link_to_a_title_excludes_that_note() {
    let mut fx = new_vault();
    let o = fx.plain("Open", "Will write [[Later Note]] soon.");
    let later = fx.plain("Later Note", "Written after the link.");
    let (to, _) = fx.link(&o, "Later Note");
    assert_eq!(to, None, "precondition: the link stayed unresolved");
    let near_title = fx.plain("Later Notes", "A different title.");
    fx.embed(&o, &q());
    fx.embed(&later, &near(0, 1, 0.95));
    fx.embed(&near_title, &near(0, 2, 0.9));

    let got = fx.run_unembedded(&o);

    assert_eq!(
        ids(&got),
        vec![near_title],
        "the title the link names is dropped"
    );
}

#[test]
fn an_unresolved_incoming_link_to_the_open_title_excludes_its_source() {
    let mut fx = new_vault();
    let source = fx.plain("Early Source", "Mentions [[Open]] before it existed.");
    let other = fx.plain("Other Source", "Mentions [[Opened]] instead.");
    let o = open_plain(&mut fx, "Open");
    let (to, _) = fx.link(&source, "Open");
    assert_eq!(to, None, "precondition: the link stayed unresolved");
    fx.embed(&source, &near(0, 1, 0.95));
    fx.embed(&other, &near(0, 2, 0.9));

    let got = fx.run_unembedded(&o);

    assert_eq!(ids(&got), vec![other], "the unresolved linker is dropped");
}

#[test]
fn an_unresolved_from_day_link_excludes_the_daily_note_of_that_date() {
    let mut fx = new_vault();
    let t = fx.topic("Jumping", "Notes on jumping.\n\n![[2026-09-05#^ab]]\n");
    let d = fx.daily("2026-09-05", "The day written after the topic.");
    let (to, kind) = fx.link(&t, "2026-09-05");
    assert_eq!(
        (to, kind.as_str()),
        (None, "from-day"),
        "precondition: unresolved"
    );
    let other_day = fx.daily("2026-09-04", "Another day.");
    fx.embed(&t, &q());
    fx.embed(&d, &near(0, 1, 0.95));
    fx.embed(&other_day, &near(0, 2, 0.9));

    let got = fx.run_unembedded(&t);

    assert_eq!(
        ids(&got),
        vec![other_day],
        "the day the token names is dropped"
    );
}

#[test]
fn an_unresolved_from_day_link_does_not_exclude_a_non_daily_note_of_that_title() {
    let mut fx = new_vault();
    // A `from-day` link resolves only to the daily note of its date
    // (links.rs), so a plain note with that title is not linked by it.
    let t = fx.topic("Jumping", "Notes on jumping.\n\n![[2026-09-07#^ab]]\n");
    let plain = fx.plain("2026-09-07", "A plain note titled like a date.");
    assert_eq!(
        fx.link(&t, "2026-09-07").0,
        None,
        "precondition: unresolved"
    );
    fx.embed(&t, &q());
    fx.embed(&plain, &near(0, 1, 0.9));

    let got = fx.run_unembedded(&t);

    assert_eq!(ids(&got), vec![plain]);
}

#[test]
fn an_open_daily_note_drops_later_days_and_keeps_earlier_days_and_other_notes() {
    let mut fx = new_vault();
    let open = fx.daily("2026-09-05", "Today I fixed the jump arc.");
    let next = fx.daily("2026-09-06", "The next day.");
    let month_later = fx.daily("2026-10-01", "A month later.");
    let earlier = fx.daily("2026-09-04", "The day before.");
    let year_earlier = fx.daily("2025-12-31", "Last year.");
    let plain = fx.plain("Jump physics", "Not a daily note.");
    fx.embed(&open, &q());
    fx.embed(&next, &near(0, 1, 0.99));
    fx.embed(&month_later, &near(0, 2, 0.98));
    fx.embed(&earlier, &near(0, 3, 0.9));
    fx.embed(&year_earlier, &near(0, 4, 0.85));
    fx.embed(&plain, &near(0, 5, 0.8));

    let got = fx.run_unembedded(&open);

    assert_eq!(
        ids(&got),
        vec![earlier, year_earlier, plain],
        "days after the open day are dropped"
    );
}

#[test]
fn an_open_non_daily_note_keeps_later_daily_notes() {
    for role in [Some("topic"), None] {
        let mut fx = new_vault();
        let fm = role.map(|r| json!({ "role": r }));
        let o = fx.create("Open", "The open note.", fm);
        fx.embed(&o, &q());
        let day = fx.daily("2099-01-01", "A day far in the future.");
        fx.embed(&day, &near(0, 1, 0.9));

        let got = fx.run_unembedded(&o);

        assert_eq!(
            ids(&got),
            vec![day],
            "role {role:?}: a dateless note draws from every day"
        );
    }
}

// ---------------------------------------------------------------- AC 2: threshold

#[test]
fn the_threshold_keeps_071_and_070_and_drops_069() {
    let mut fx = new_vault();
    let o = open_plain(&mut fx, "Open");
    let above = fx.plain("Above", "Seventy-one.");
    let at = fx.plain("At", "Seventy.");
    let below = fx.plain("Below", "Sixty-nine.");
    fx.embed(&above, &near(0, 1, 0.71));
    fx.embed(&at, &exactly_threshold());
    fx.embed(&below, &near(0, 3, 0.69));

    let got = fx.run_unembedded(&o);

    assert_eq!(
        ids(&got),
        vec![above, at],
        "0.71 and 0.70 kept, 0.69 dropped"
    );
}

// ---------------------------------------------------------------- AC 3: one per note

#[test]
fn a_note_with_three_matching_chunks_yields_one_echo_from_its_best_chunk() {
    let mut fx = new_vault();
    let o = open_plain(&mut fx, "Open");
    let body = format!(
        "{}\n\n{}\n\n{}",
        big_block("First é chunk."),
        big_block("Second 🎉 chunk."),
        big_block("Third chunk."),
    );
    let many = fx.plain("Many", &body);
    fx.embed_each(&many, &[near(0, 1, 0.8), near(0, 2, 0.9), near(0, 3, 0.75)]);
    let single = fx.plain("Single", "One chunk.");
    fx.embed(&single, &near(0, 4, 0.85));

    let got = fx.run_unembedded(&o);

    assert_eq!(
        ids(&got),
        vec![many.clone(), single],
        "one echo for Many, scored 0.9"
    );
    let echo = the_echo(&got, &many);
    let best = fx.chunks(&many)[1].clone();
    assert_eq!(
        echo.passage, best.content,
        "the passage is the best chunk's block"
    );
    let start = best.start_byte.unwrap() as usize;
    assert_eq!(echo.start_byte, Some(start));
    assert!(fx.body(&many)[start..].starts_with(&echo.passage));
}

// ---------------------------------------------------------------- AC 4: ordering

#[test]
fn echoes_are_ordered_by_score_descending() {
    let mut fx = new_vault();
    let o = open_plain(&mut fx, "Open");
    // Lowest score: smallest id and newest; highest score: largest id, oldest.
    let low = fx.note_with_id("01KZZZZZZZZZZZZZZZZZZZZZA1", "Low", "Low.", 3_000);
    let mid = fx.note_with_id("01KZZZZZZZZZZZZZZZZZZZZZA2", "Mid", "Mid.", 2_000);
    let high = fx.note_with_id("01KZZZZZZZZZZZZZZZZZZZZZA3", "High", "High.", 1_000);
    fx.embed(&low, &near(0, 1, 0.75));
    fx.embed(&mid, &near(0, 2, 0.8));
    fx.embed(&high, &near(0, 3, 0.9));

    let got = fx.run_unembedded(&o);

    assert_eq!(ids(&got), vec![high, mid, low]);
}

#[test]
fn equal_scores_order_by_updated_at_descending() {
    let mut fx = new_vault();
    let o = open_plain(&mut fx, "Open");
    let older = fx.note_with_id("01KZZZZZZZZZZZZZZZZZZZZZB1", "Older", "Older.", 1_000);
    let newer = fx.note_with_id("01KZZZZZZZZZZZZZZZZZZZZZB2", "Newer", "Newer.", 2_000);
    let v = near(0, 1, 0.8);
    fx.embed(&older, &v);
    fx.embed(&newer, &v);

    let got = fx.run_unembedded(&o);

    assert_eq!(ids(&got), vec![newer.clone(), older.clone()]);
    assert_eq!(the_echo(&got, &newer).note_updated_at, 2_000);
    assert_eq!(the_echo(&got, &older).note_updated_at, 1_000);
}

#[test]
fn equal_scores_and_updated_at_order_by_note_id_ascending() {
    let mut fx = new_vault();
    let o = open_plain(&mut fx, "Open");
    // Inserted (rowid) in the reverse of id order.
    let second = fx.note_with_id("01KZZZZZZZZZZZZZZZZZZZZZC2", "Second", "Second.", 5_000);
    let first = fx.note_with_id("01KZZZZZZZZZZZZZZZZZZZZZC1", "First", "First.", 5_000);
    let v = near(0, 1, 0.8);
    fx.embed(&second, &v);
    fx.embed(&first, &v);

    let got = fx.run_unembedded(&o);

    assert_eq!(ids(&got), vec![first, second]);
}

#[test]
fn limit_truncates_to_the_best_echoes() {
    let mut fx = new_vault();
    let o = open_plain(&mut fx, "Open");
    let mut notes = Vec::new();
    for (i, s) in [0.95, 0.9, 0.85, 0.8, 0.75].into_iter().enumerate() {
        let n = fx.plain(&format!("Candidate {i}"), &format!("Candidate {i}."));
        fx.embed(&n, &near(0, 1 + i, s));
        notes.push(n);
    }

    let three = fx.run(&no_embedding(), &o, 3);
    let one = fx.run(&no_embedding(), &o, 1);
    let all = fx.run(&no_embedding(), &o, 20);

    assert_eq!(ids(&three), notes[..3].to_vec());
    assert_eq!(ids(&one), notes[..1].to_vec());
    assert_eq!(ids(&all), notes, "a limit above the candidates keeps all");
}

// ---------------------------------------------------------------- AC 5: topic queries

/// A day with three one-block chunks (pinned block ids) and a topic made
/// only of `token`. The day's chunks get `e(1)`, `Q`, `e(2)` by ord.
fn transclusion_topic(fx: &mut Fx, topic_body: &str) -> (String, String) {
    let d = fx.daily("2026-09-05", &long_day_body());
    fx.pin_day_blocks(&d);
    fx.embed_each(&d, &[e(1), q(), e(2)]);
    let t = fx.topic("Jumping", topic_body);
    (d, t)
}

#[test]
fn a_topic_made_only_of_transclusions_queries_with_the_transcluded_days_chunks() {
    let mut fx = new_vault();
    let (_d, t) = transclusion_topic(&mut fx, "![[2026-09-05#^c3d4e5]]\n");
    assert!(
        fx.chunks(&t).is_empty(),
        "precondition: the topic has no chunks"
    );
    let via_block = fx.plain("Coyote time", "Close to the transcluded block.");
    let via_other_block = fx.plain("Jump arc", "Close to a block not transcluded.");
    let via_third_block = fx.plain("Sleep", "Close to the third block.");
    fx.embed(&via_block, &near(0, 3, 0.9));
    fx.embed(&via_other_block, &near(1, 4, 0.9));
    fx.embed(&via_third_block, &near(2, 5, 0.9));

    let got = fx.run_unembedded(&t);

    assert_eq!(
        got.reason, None,
        "a topic of transclusions is not empty_note"
    );
    assert_eq!(
        ids(&got),
        vec![via_block],
        "only the chunk overlapping the transcluded block is a query vector"
    );
}

#[test]
fn a_range_transclusion_queries_with_every_overlapping_day_chunk() {
    let mut fx = new_vault();
    let (_d, t) = transclusion_topic(&mut fx, "![[2026-09-05#^b7k2m9..^c3d4e5]]\n");
    let via_first = fx.plain("Jump arc", "Close to block 0.");
    let via_second = fx.plain("Coyote time", "Close to block 1.");
    let via_third = fx.plain("Sleep", "Close to block 2.");
    fx.embed(&via_first, &near(1, 4, 0.85));
    fx.embed(&via_second, &near(0, 3, 0.9));
    fx.embed(&via_third, &near(2, 5, 0.9));

    let got = fx.run_unembedded(&t);

    assert_eq!(ids(&got), vec![via_second, via_first]);
}

#[test]
fn a_topic_queries_with_its_own_chunks_and_its_transcluded_blocks() {
    let mut fx = new_vault();
    let (_d, t) = transclusion_topic(
        &mut fx,
        "Own words on jumping.\n\n![[2026-09-05#^c3d4e5]]\n",
    );
    fx.embed(&t, &e(6));
    let via_own = fx.plain("Own words", "Close to the topic's own chunk.");
    let via_block = fx.plain("Coyote time", "Close to the transcluded block.");
    fx.embed(&via_own, &near(6, 7, 0.95));
    fx.embed(&via_block, &near(0, 3, 0.9));

    let got = fx.run_unembedded(&t);

    assert_eq!(ids(&got), vec![via_own, via_block]);
}

// ---------------------------------------------------------------- AC 6: adaptive k

/// Gives `note` `n` hand-made chunks (its own chunks dropped), each with a
/// vector at similarity `s` to `Q`, so they rank ahead of a weaker echo.
fn crowd(fx: &Fx, note: &str, tag: &str, n: usize, s: f32) {
    fx.clear_chunks(note);
    for i in 0..n {
        fx.raw_chunk(
            &format!("01KCROWD{tag}{i:05}"),
            note,
            i as i64,
            &format!("crowd {tag} {i}"),
            Some(&near(0, 1, s)),
        );
    }
}

#[test]
fn fifty_excluded_chunks_ranked_ahead_still_let_the_echo_through() {
    let mut fx = new_vault();
    let open = fx.daily("2026-09-05", "Today.");
    fx.embed(&open, &q());
    // k starts at 50 + E = 51: the own chunk and 50 later-day chunks fill it.
    let later = fx.daily("2026-09-06", "Tomorrow.");
    crowd(&fx, &later, "L", 50, 0.95);
    let echo = fx.plain("Echo", "The valid echo.");
    fx.embed(&echo, &near(0, 2, 0.8));

    let got = fx.run_unembedded(&open);

    assert_eq!(ids(&got), vec![echo]);
}

#[test]
fn adaptive_k_doubles_up_to_400() {
    let mut fx = new_vault();
    let o = open_plain(&mut fx, "Open");
    // The own chunk and 398 guide chunks rank ahead: the echo is 400th.
    let g = fx.guide();
    crowd(&fx, &g, "G", 398, 0.95);
    let echo = fx.plain("Echo", "The valid echo.");
    fx.embed(&echo, &near(0, 2, 0.8));

    let got = fx.run_unembedded(&o);

    assert_eq!(ids(&got), vec![echo], "k reaches 400 (51, 102, 204, 400)");
}

#[test]
fn adaptive_k_never_passes_400() {
    let mut fx = new_vault();
    let o = open_plain(&mut fx, "Open");
    let first = fx.plain("First", "Ranked second, right after the own chunk.");
    fx.embed(&first, &near(0, 3, 0.99));
    // The own chunk, First and 398 guide chunks fill k = 400: the echo is 401st.
    let g = fx.guide();
    crowd(&fx, &g, "G", 398, 0.95);
    let beyond = fx.plain("Beyond", "Past the cap.");
    fx.embed(&beyond, &near(0, 2, 0.8));

    let got = fx.run_unembedded(&o);

    assert_eq!(ids(&got), vec![first], "the 401st chunk is never reached");
}

#[test]
fn k_starts_at_50_plus_the_chunks_of_the_open_and_linked_notes() {
    // E counts the linked notes' chunks: 400 of them ahead of the echo are
    // more than doubling alone (capped at 400) could ever get past.
    let mut fx = new_vault();
    let linked = fx.plain("Linked", "Linked note.");
    let o = fx.plain("Open", "Links to [[Linked]].");
    fx.embed(&o, &q());
    crowd(&fx, &linked, "K", 400, 0.95);
    let echo = fx.plain("Echo", "The valid echo.");
    fx.embed(&echo, &near(0, 2, 0.8));

    let got = fx.run_unembedded(&o);

    assert_eq!(ids(&got), vec![echo], "k = 50 + 401 reaches the echo");
}

#[test]
fn k_counts_the_open_notes_own_chunks() {
    let mut fx = new_vault();
    let o = fx.plain("Open", "Placeholder.");
    fx.clear_chunks(&o);
    for i in 0..400 {
        fx.raw_chunk(
            &format!("01KOWN{i:05}"),
            &o,
            i,
            &format!("own {i}"),
            Some(&q()),
        );
    }
    let echo = fx.plain("Echo", "The valid echo.");
    fx.embed(&echo, &near(0, 2, 0.8));

    let got = fx.run_unembedded(&o);

    assert_eq!(ids(&got), vec![echo], "k = 50 + 400 reaches the echo");
}

// ---------------------------------------------------------------- AC 7: best block

#[test]
fn the_passage_is_the_block_most_similar_to_the_query() {
    let mut fx = new_vault();
    let o = open_plain(&mut fx, "Open");
    let c = fx.plain(
        "Blocks",
        "Low block one.\n\nBest block two.\n\nMiddling block three.",
    );
    assert_eq!(
        fx.chunks(&c).len(),
        1,
        "precondition: one chunk of three blocks"
    );
    fx.embed(&c, &near(0, 1, 0.9));
    let table = TableEmbedder::new(DIM)
        .with("Low block one.", near(0, 2, 0.2))
        .with("Best block two.", near(0, 3, 0.95))
        .with("Middling block three.", near(0, 4, 0.6));

    let got = fx.run(&table, &o, LIMIT);

    let echo = the_echo(&got, &c);
    assert_eq!(echo.passage, "Best block two.");
    assert_eq!(table.calls(), 1, "the blocks are embedded");
}

#[test]
fn the_passage_is_chosen_against_the_query_vector_that_scored_the_chunk() {
    let mut fx = new_vault();
    let body = format!(
        "{}\n\n{}",
        big_block("Own first."),
        big_block("Own second.")
    );
    let o = fx.plain("Open", &body);
    // Query 1 is e(0), query 2 is e(4).
    fx.embed_each(&o, &[e(0), e(4)]);
    let c = fx.plain("Blocks", "Like query one.\n\nLike query two.");
    // 0.705 to query 1, 0.709 to query 2: query 2 gives the score.
    let mut v = vec![0.0; DIM];
    v[0] = 0.705;
    v[4] = 0.709;
    v[7] = (1.0f32 - 0.705 * 0.705 - 0.709 * 0.709).sqrt();
    fx.embed(&c, &v);
    let table = TableEmbedder::new(DIM)
        .with("Like query one.", e(0))
        .with("Like query two.", e(4));

    let got = fx.run(&table, &o, LIMIT);

    assert_eq!(the_echo(&got, &c).passage, "Like query two.");
}

#[test]
fn a_tie_between_blocks_goes_to_the_earlier_block() {
    let mut fx = new_vault();
    let o = open_plain(&mut fx, "Open");
    let c = fx.plain(
        "Blocks",
        "Weak block.\n\nTied block early.\n\nTied block late.",
    );
    fx.embed(&c, &near(0, 1, 0.9));
    let tied = near(0, 3, 0.9);
    let table = TableEmbedder::new(DIM)
        .with("Weak block.", near(0, 2, 0.1))
        .with("Tied block early.", tied.clone())
        .with("Tied block late.", tied);

    let got = fx.run(&table, &o, LIMIT);

    assert_eq!(the_echo(&got, &c).passage, "Tied block early.");
}

#[test]
fn start_byte_points_at_the_chosen_block_in_the_full_body() {
    let mut fx = new_vault();
    let o = open_plain(&mut fx, "Open");
    let body = format!(
        "{}\n\nFirst small block é.\n\nSecond small block 🎉 target.\n\nThird small block.",
        big_block("Ünïcødé 😀 lead.")
    );
    let c = fx.plain("Blocks", &body);
    let chunks = fx.chunks(&c);
    assert_eq!(
        chunks.len(),
        2,
        "precondition: a lead chunk, then a three-block chunk"
    );
    assert!(chunks[1].start_byte.unwrap() > 0);
    fx.embed_each(&c, &[e(5), near(0, 1, 0.9)]);
    let table = TableEmbedder::new(DIM)
        .with("First small block é.", near(0, 2, 0.3))
        .with("Second small block 🎉 target.", near(0, 3, 0.95))
        .with("Third small block.", near(0, 4, 0.5));

    let got = fx.run(&table, &o, LIMIT);

    let echo = the_echo(&got, &c);
    assert_eq!(echo.passage, "Second small block 🎉 target.");
    let expected = body.find("Second small block").unwrap();
    assert_eq!(echo.start_byte, Some(expected));
    let stored = fx.body(&c);
    assert!(stored[expected..].starts_with(&echo.passage));
}

#[test]
fn the_best_block_batch_is_embedded_with_no_lease_held() {
    let mut fx = new_vault();
    let o = open_plain(&mut fx, "Open");
    let c = fx.plain("Blocks", "Low block.\n\nBest block.");
    fx.embed(&c, &near(0, 1, 0.9));
    let gated = GatedEmbedder::new(
        TableEmbedder::new(DIM)
            .with("Low block.", near(0, 2, 0.2))
            .with("Best block.", near(0, 3, 0.95)),
    );
    let (_dir, shared) = into_shared(fx);

    let got = std::thread::scope(|s| {
        let _release = ReleaseOnDrop(&gated);
        let run = s.spawn(|| {
            let _release = ReleaseOnDrop(&gated);
            let mut lease = MutexLease { conn: &shared };
            echoes(&mut lease, &gated, &o, LIMIT, 64)
        });
        assert!(gated.wait_entered(), "echoes never embedded the blocks");
        drop(
            shared
                .try_lock()
                .expect("the vault mutex is free while the blocks are embedded"),
        );
        gated.release();
        run.join().unwrap()
    });

    let got = got.unwrap();
    assert_eq!(the_echo(&got, &c).passage, "Best block.");
}

/// The vault server's shape: each lease locks a shared mutex.
struct MutexLease<'a> {
    conn: &'a Mutex<Connection>,
}

impl ConnLease for MutexLease<'_> {
    fn lease<R>(&mut self, f: impl FnOnce(&mut Connection) -> Result<R>) -> Result<R> {
        let mut guard = self.conn.lock().unwrap();
        f(&mut guard)
    }
}

/// Releases the gate when dropped, so no thread stays blocked.
struct ReleaseOnDrop<'a>(&'a GatedEmbedder);

impl Drop for ReleaseOnDrop<'_> {
    fn drop(&mut self) {
        self.0.release();
    }
}

fn into_shared(fx: Fx) -> (tempfile::TempDir, Mutex<Connection>) {
    let Fx { _dir, db, vault } = fx;
    drop(vault);
    let c = Connection::open(&db).unwrap();
    c.busy_timeout(Duration::from_secs(5)).unwrap();
    (_dir, Mutex::new(c))
}

// ---------------------------------------------------------------- AC 8: the 64-text cap

/// A one-chunk note of `n` short blocks `"<tag> block NN"`, whose block
/// `best` is the closest to `Q`. Adds every block's vector to `table`.
fn blocky(fx: &mut Fx, table: &mut TableEmbedder, tag: &str, n: usize, best: usize) -> String {
    let blocks: Vec<String> = (0..n).map(|i| format!("{tag} block {i:02}")).collect();
    let note = fx.plain(tag, &blocks.join("\n\n"));
    assert_eq!(
        fx.chunks(&note).len(),
        1,
        "precondition: {tag} is one chunk"
    );
    for (i, b) in blocks.iter().enumerate() {
        let v = if i == best { near(0, 3, 0.95) } else { e(6) };
        table.insert(b.clone(), v);
    }
    note
}

#[test]
fn blocks_that_fit_in_64_texts_all_get_their_best_block() {
    let mut fx = new_vault();
    let o = open_plain(&mut fx, "Open");
    let mut table = TableEmbedder::new(DIM);
    let a = blocky(&mut fx, &mut table, "Alpha", 34, 17);
    let b = blocky(&mut fx, &mut table, "Beta", 30, 29);
    fx.embed(&a, &near(0, 1, 0.95));
    fx.embed(&b, &near(0, 2, 0.9));
    let rec = Recording::new(table);

    let got = fx.run(&rec, &o, LIMIT);

    assert_eq!(ids(&got), vec![a.clone(), b.clone()]);
    assert_eq!(the_echo(&got, &a).passage, "Alpha block 17");
    assert_eq!(
        the_echo(&got, &b).passage,
        "Beta block 29",
        "34 + 30 = 64 fits"
    );
    let batches = rec.batches();
    assert!(
        batches.iter().all(|b| b.len() <= 64),
        "{:?}",
        sizes(&batches)
    );
    assert_eq!(batches.iter().map(Vec::len).sum::<usize>(), 64);
}

#[test]
fn a_later_chunk_whose_blocks_no_longer_fit_uses_its_first_block() {
    let mut fx = new_vault();
    let o = open_plain(&mut fx, "Open");
    let mut table = TableEmbedder::new(DIM);
    let a = blocky(&mut fx, &mut table, "Alpha", 40, 17);
    let b = blocky(&mut fx, &mut table, "Beta", 30, 29);
    // Alpha ranks first, so its 40 blocks are taken first.
    fx.embed(&a, &near(0, 1, 0.95));
    fx.embed(&b, &near(0, 2, 0.9));
    let rec = Recording::new(table);

    let got = fx.run(&rec, &o, LIMIT);

    assert_eq!(ids(&got), vec![a.clone(), b.clone()]);
    assert_eq!(the_echo(&got, &a).passage, "Alpha block 17");
    assert_eq!(the_echo(&got, &b).passage, "Beta block 00", "40 + 30 > 64");
    let batches = rec.batches();
    assert!(
        batches.iter().all(|b| b.len() <= 64),
        "{:?}",
        sizes(&batches)
    );
    assert_eq!(
        batches.iter().map(Vec::len).sum::<usize>(),
        40,
        "only Alpha's blocks are embedded"
    );
    let b_body = fx.body(&b);
    let echo = the_echo(&got, &b);
    assert!(b_body[echo.start_byte.unwrap()..].starts_with("Beta block 00"));
}

fn sizes(batches: &[Vec<String>]) -> Vec<usize> {
    batches.iter().map(Vec::len).collect()
}

// ---------------------------------------------------------------- AC 9: empty_note

#[test]
fn a_note_with_no_chunks_and_no_transclusions_is_empty_note() {
    for body in ["", "  \n\n  \n"] {
        let mut fx = new_vault();
        let o = fx.plain("Empty", body);
        assert!(fx.chunks(&o).is_empty(), "precondition: no chunks");
        let other = fx.plain("Other", "Something.");
        fx.embed(&other, &q());

        let got = fx.run_unembedded(&o);

        assert_eq!(got.reason, Some("empty_note"), "body {body:?}");
        assert!(got.echoes.is_empty());
    }
}

#[test]
fn a_note_with_chunks_has_no_reason() {
    let mut fx = new_vault();
    let o = open_plain(&mut fx, "Open");
    let other = fx.plain("Other", "Something.");
    fx.embed(&other, &near(0, 1, 0.9));

    let got = fx.run_unembedded(&o);

    assert_eq!((got.reason, ids(&got)), (None, vec![other]));
}

// ---------------------------------------------------------------- AC 10: null start_byte

#[test]
fn a_chunk_without_start_byte_gives_a_null_start_byte() {
    let mut fx = new_vault();
    let o = open_plain(&mut fx, "Open");
    let single = fx.plain("Single", "One old block.");
    let multi = fx.plain("Multi", "Old first block.\n\nOld second block.");
    for n in [&single, &multi] {
        fx.conn()
            .execute(
                "UPDATE chunks SET start_byte = NULL, end_byte = NULL WHERE note_id = ?",
                [n],
            )
            .unwrap();
    }
    fx.embed(&single, &near(0, 1, 0.95));
    fx.embed(&multi, &near(0, 2, 0.9));
    let table = TableEmbedder::new(DIM)
        .with("Old first block.", e(6))
        .with("Old second block.", near(0, 3, 0.9));

    let got = fx.run(&table, &o, LIMIT);

    let s = the_echo(&got, &single);
    assert_eq!((s.passage.as_str(), s.start_byte), ("One old block.", None));
    let m = the_echo(&got, &multi);
    assert_eq!(
        (m.passage.as_str(), m.start_byte),
        ("Old second block.", None)
    );
    let json = serde_json::to_value(&got).unwrap();
    assert_eq!(json["echoes"][0]["start_byte"], Value::Null);
}

// ---------------------------------------------------------------- AC 11: lazy model

#[test]
fn nothing_to_embed_never_calls_the_embedder() {
    let mut fx = new_vault();
    let o = open_plain(&mut fx, "Open");
    let kept = fx.plain("Kept", "One block only.");
    fx.embed(&kept, &near(0, 1, 0.95));
    // Multi-block chunks that are not kept: past the limit, below the
    // threshold, or excluded by a link.
    let past_limit = fx.plain("Past limit", "Block one.\n\nBlock two.");
    fx.embed(&past_limit, &near(0, 2, 0.9));
    let below = fx.plain("Below", "Block three.\n\nBlock four.");
    fx.embed(&below, &near(0, 3, 0.5));
    let linked = fx.plain("Linker", "See [[Open]].\n\nBlock five.");
    fx.embed(&linked, &near(0, 4, 0.99));
    let table = no_embedding();

    let got = fx.run(&table, &o, 1);

    assert_eq!(ids(&got), vec![kept.clone()]);
    assert_eq!(the_echo(&got, &kept).passage, "One block only.");
    assert_eq!(table.calls(), 0, "the embedder is never called");
}

// ---------------------------------------------------------------- AC 12: pending

/// An open note with `own` unembedded chunks (texts in `table`, vector
/// `Q`), a pre-embedded echo, and another note with `others` unembedded
/// chunks (vectors far from `Q`).
fn unembedded_vault(own: usize, others: usize) -> (Fx, TableEmbedder, String, String) {
    let mut fx = new_vault();
    let mut table = TableEmbedder::new(DIM);
    let o = fx.plain("Open", "Placeholder.");
    fx.clear_chunks(&o);
    for i in 0..own {
        let text = format!("open chunk {i:02}");
        fx.raw_chunk(&format!("01KOPEN{i:05}"), &o, i as i64, &text, None);
        table.insert(text, q());
    }
    let z = fx.plain("Backlog", "Placeholder.");
    fx.clear_chunks(&z);
    for i in 0..others {
        let text = format!("backlog chunk {i:02}");
        fx.raw_chunk(&format!("01KBACK{i:05}"), &z, i as i64, &text, None);
        table.insert(text, e(7));
    }
    let echo = fx.plain("Echo", "A single block.");
    fx.embed(&echo, &near(0, 1, 0.9));
    (fx, table, o, echo)
}

#[test]
fn pending_is_embed_missings_count() {
    for (others_cap, pending) in [(0, 3), (1, 2), (64, 0)] {
        let (mut fx, table, o, echo) = unembedded_vault(2, 3);

        let got = fx.try_run(&table, &o, LIMIT, others_cap).unwrap();

        assert_eq!(got.pending, pending, "others_cap {others_cap}");
        assert_eq!(
            ids(&got),
            vec![echo],
            "the open note's chunks, embedded first, are the query vectors"
        );
    }
}

#[test]
fn the_open_notes_chunks_are_embedded_up_to_32() {
    let (mut fx, table, o, echo) = unembedded_vault(33, 0);

    let got = fx.try_run(&table, &o, LIMIT, 64).unwrap();

    assert_eq!(
        got.pending, 1,
        "32 of the open note's 33 chunks are embedded"
    );
    assert_eq!(ids(&got), vec![echo]);
}

// ---------------------------------------------------------------- AC 13: NotFound

#[test]
fn a_missing_note_is_not_found() {
    let mut fx = new_vault();
    let other = fx.plain("Other", "Something.");
    fx.embed(&other, &q());

    let err = fx
        .try_run(&no_embedding(), "01KNOSUCHNOTE0000000000000", LIMIT, 64)
        .unwrap_err();

    assert!(matches!(err, MemexError::NotFound(_)), "got {err:?}");
}

// ---------------------------------------------------------------- result fields

#[test]
fn each_echo_carries_its_notes_title_role_day_and_updated_at() {
    let mut fx = new_vault();
    let o = open_plain(&mut fx, "Open");
    let day = fx.daily("2026-09-04", "A day.");
    let topic = fx.topic("A topic", "A topic.");
    let plain = fx.plain("A plain note", "A plain note.");
    fx.embed(&day, &near(0, 1, 0.95));
    fx.embed(&topic, &near(0, 2, 0.9));
    fx.embed(&plain, &near(0, 3, 0.85));
    fx.set_updated_at(&topic, 1_234);

    let got = fx.run_unembedded(&o);

    assert_eq!(names(&fx, &got), ["2026-09-04", "A topic", "A plain note"]);
    let d = the_echo(&got, &day);
    assert_eq!(
        (
            d.note_title.as_str(),
            d.note_role.as_deref(),
            d.day.as_deref()
        ),
        ("2026-09-04", Some("daily"), Some("2026-09-04"))
    );
    assert_eq!(d.note_updated_at, fx.updated_at(&day));
    let t = the_echo(&got, &topic);
    assert_eq!(
        (
            t.note_title.as_str(),
            t.note_role.as_deref(),
            t.day.as_deref()
        ),
        ("A topic", Some("topic"), None)
    );
    assert_eq!(t.note_updated_at, 1_234);
    let p = the_echo(&got, &plain);
    assert_eq!(
        (
            p.note_title.as_str(),
            p.note_role.as_deref(),
            p.day.as_deref()
        ),
        ("A plain note", None, None)
    );
}

#[test]
fn echoes_serialize_with_the_contract_field_names() {
    let mut fx = new_vault();
    let o = open_plain(&mut fx, "Open");
    let p = fx.plain("Plain", "A plain note.");
    fx.embed(&p, &near(0, 1, 0.9));

    let got = fx.run_unembedded(&o);

    let json = serde_json::to_value(&got).unwrap();
    let mut top: Vec<&str> = json
        .as_object()
        .unwrap()
        .keys()
        .map(String::as_str)
        .collect();
    top.sort_unstable();
    assert_eq!(top, ["echoes", "pending", "reason"]);
    let echo = json["echoes"][0].as_object().expect("one echo");
    let mut keys: Vec<&str> = echo.keys().map(String::as_str).collect();
    keys.sort_unstable();
    assert_eq!(
        keys,
        [
            "day",
            "note_id",
            "note_role",
            "note_title",
            "note_updated_at",
            "passage",
            "start_byte"
        ]
    );
    assert_eq!(json["reason"], Value::Null);
}

// ---------------------------------------------------------------- verify: pinned contracts

/// Answers every batch with one vector fewer than it was given.
struct ShortBatch(TableEmbedder);

impl Embedder for ShortBatch {
    fn model_version(&self) -> &str {
        self.0.model_version()
    }

    fn dimension(&self) -> usize {
        self.0.dimension()
    }

    fn embed_batch(&self, texts: &[String]) -> Result<Vec<Vec<f32>>> {
        let mut v = self.0.embed_batch(texts)?;
        v.pop();
        Ok(v)
    }
}

#[test]
fn equal_scoring_chunks_of_one_note_give_the_earlier_chunk() {
    let mut fx = new_vault();
    let o = open_plain(&mut fx, "Open");
    let body = format!(
        "{}\n\n{}",
        big_block("Earlier chunk."),
        big_block("Later chunk.")
    );
    let many = fx.plain("Many", &body);
    assert_eq!(fx.chunks(&many).len(), 2, "precondition: two chunks");
    let same = near(0, 1, 0.9);
    fx.embed_each(&many, &[same.clone(), same]);

    let got = fx.run_unembedded(&o);

    let echo = the_echo(&got, &many);
    assert!(
        echo.passage.starts_with("Earlier chunk."),
        "a tie keeps the lower ord: {}",
        &echo.passage[..20]
    );
}

#[test]
fn a_zero_block_vector_scores_zero_not_nan() {
    let mut fx = new_vault();
    let o = open_plain(&mut fx, "Open");
    let c = fx.plain("Blocks", "Zero block.\n\nOpposed block.");
    fx.embed(&c, &near(0, 1, 0.9));
    let mut opposed = vec![0.0; DIM];
    opposed[0] = -1.0;
    let table = TableEmbedder::new(DIM)
        .with("Zero block.", vec![0.0; DIM])
        .with("Opposed block.", opposed);

    let got = fx.run(&table, &o, LIMIT);

    assert_eq!(
        the_echo(&got, &c).passage,
        "Zero block.",
        "cosine 0 beats cosine -1"
    );
}

#[test]
fn an_embedder_that_returns_the_wrong_number_of_block_vectors_is_an_embedder_error() {
    let mut fx = new_vault();
    let o = open_plain(&mut fx, "Open");
    let c = fx.plain("Blocks", "Block one.\n\nBlock two.");
    fx.embed(&c, &near(0, 1, 0.9));
    let table = TableEmbedder::new(DIM)
        .with("Block one.", e(2))
        .with("Block two.", e(3));

    let err = fx
        .try_run(&ShortBatch(table), &o, LIMIT, 64)
        .expect_err("a short batch must not pass");

    assert!(matches!(err, MemexError::EmbedderInfer(_)), "{err:?}");
}

// ---------------------------------------------------------------- fix round 1: k formula and clamp

/// An open note of nine own chunks (one on `Q`, eight on `e(7)`), so `E = 9`
/// and k starts at 59. `guards` guide chunks at 0.96 to `e(7)` follow the
/// eight own chunks in `e(7)`'s kNN, so note B (0.95 to `e(7)`) ranks
/// `8 + guards + 1`th there. Note A (0.75 to `Q`) ranks 2nd for `Q`. Returns
/// `(fx, open, a, b)`.
fn k_probe(guards: usize) -> (Fx, String, String, String) {
    let mut fx = new_vault();
    let o = fx.plain("Open", "Placeholder.");
    fx.clear_chunks(&o);
    fx.raw_chunk("01KPROBEOWN00000", &o, 0, "own on Q", Some(&q()));
    for i in 1..9 {
        fx.raw_chunk(
            &format!("01KPROBEOWN{i:05}"),
            &o,
            i,
            &format!("own on e7 {i}"),
            Some(&e(7)),
        );
    }
    let g = fx.guide();
    fx.clear_chunks(&g);
    for i in 0..guards {
        fx.raw_chunk(
            &format!("01KPROBEGRD{i:05}"),
            &g,
            i as i64,
            &format!("guard {i}"),
            Some(&near(7, 6, 0.96)),
        );
    }
    let a = fx.plain("Reach A", "Found by the first query.");
    fx.embed(&a, &near(0, 1, 0.75));
    let b = fx.plain("Reach B", "Found by the second query.");
    fx.embed(&b, &near(7, 6, 0.95));
    (fx, o, a, b)
}

#[test]
fn the_first_knn_round_reaches_rank_50_plus_e_and_a_satisfied_limit_stops_there() {
    // E = 9 so k = 59. B is the 59th row of e(7)'s kNN: it is in the first
    // round, which already holds A and B, so the best of them, B, is returned.
    let (mut fx, o, _a, b) = k_probe(50);

    let got = fx.try_run(&no_embedding(), &o, 1, 0).unwrap();

    assert_eq!(ids(&got), vec![b]);
}

#[test]
fn the_first_knn_round_stops_at_rank_50_plus_e() {
    // B is the 60th row of e(7)'s kNN: past k = 59. A fills the limit of 1 in
    // the first round, so k is not doubled and B is never seen. A larger
    // start (50 * E, 51 + E) would have reached it.
    let (mut fx, o, a, _b) = k_probe(51);

    let got = fx.try_run(&no_embedding(), &o, 1, 0).unwrap();

    assert_eq!(ids(&got), vec![a]);
}

#[test]
fn k_doubles_when_fewer_than_limit_notes_qualify() {
    // The same B at rank 60, but a limit of 2: one qualifying note is fewer
    // than 2, so k doubles to 118 and B comes through.
    let (mut fx, o, a, b) = k_probe(51);

    let got = fx.try_run(&no_embedding(), &o, 2, 0).unwrap();

    assert_eq!(ids(&got), vec![b, a]);
}

#[test]
fn k_is_clamped_to_sqlite_vecs_limit_for_a_hub_note_with_thousands_of_linked_chunks() {
    // sqlite-vec errors on k > 4096. E counts every chunk of every linked
    // note, so a hub with 4100 of them would start above it unclamped.
    let mut fx = new_vault();
    let linked = fx.plain("Hub topic", "Filed on thousands of days.");
    fx.clear_chunks(&linked);
    fx.conn().execute_batch("BEGIN").unwrap();
    for i in 0..4100 {
        fx.raw_chunk(
            &format!("01KHUB{i:07}"),
            &linked,
            i,
            &format!("hub chunk {i}"),
            None,
        );
    }
    fx.conn().execute_batch("COMMIT").unwrap();
    let o = fx.plain("Open", "Linked to [[Hub topic]].");
    fx.embed(&o, &q());
    let echo = fx.plain("Echo", "The valid echo.");
    fx.embed(&echo, &near(0, 2, 0.8));

    let got = fx
        .try_run(&no_embedding(), &o, LIMIT, 0)
        .expect("k above sqlite-vec's limit must be clamped, not an error");

    assert_eq!(ids(&got), vec![echo]);
}

// ---------------------------------------------------------------- fix round 1: unresolved incoming from-day

#[test]
fn an_unresolved_incoming_from_day_link_excludes_its_topic_when_the_open_note_is_that_daily_note() {
    let mut fx = new_vault();
    // The topic's token named a day that did not exist yet, so its link is
    // unresolved; the daily note is created afterwards and opened.
    let t = fx.topic("Jumping", "Notes on jumping.\n\n![[2026-09-05#^ab]]\n");
    let d = fx.daily("2026-09-05", "The day written after the topic.");
    let (to, kind) = fx.link(&t, "2026-09-05");
    assert_eq!(
        (to, kind.as_str()),
        (None, "from-day"),
        "precondition: unresolved"
    );
    let other = fx.plain("Other", "Unrelated note.");
    fx.embed(&d, &q());
    fx.embed(&t, &near(0, 1, 0.95));
    fx.embed(&other, &near(0, 2, 0.9));

    let got = fx.run_unembedded(&d);

    assert_eq!(ids(&got), vec![other], "the topic that names this day");
}

#[test]
fn an_unresolved_incoming_from_day_link_does_not_exclude_its_topic_for_a_plain_note_of_that_title()
{
    let mut fx = new_vault();
    let t = fx.topic("Jumping", "Notes on jumping.\n\n![[2026-09-05#^ab]]\n");
    let o = fx.plain("2026-09-05", "A plain note titled like a date.");
    assert_eq!(
        fx.link(&t, "2026-09-05").0,
        None,
        "precondition: unresolved (a from-day link resolves only to a daily note)"
    );
    fx.embed(&o, &q());
    fx.embed(&t, &near(0, 1, 0.95));

    let got = fx.run_unembedded(&o);

    assert_eq!(ids(&got), vec![t]);
}

// ---------------------------------------------------------------- fix round 1: transclusion by byte overlap

impl Fx {
    /// Gives block `ord` of `note` the block id `id`.
    fn pin_block(&self, note: &str, ord: i64, id: &str) {
        let n = self
            .conn()
            .execute(
                "UPDATE blocks SET block_id = ? WHERE note_id = ? AND ord = ?",
                params![id, note, ord],
            )
            .unwrap();
        assert_eq!(n, 1, "precondition: {note} has block {ord}");
    }
}

/// A day of five blocks in three chunks: Alpha, Bravo and Charlie share
/// chunk 0; Delta (block 3) is chunk 1 and Echo (block 4) chunk 2. The
/// chunks get `Q`, `e(1)`, `e(2)`; Bravo is `^b7k2m9`, Charlie `^c3d4e5`,
/// Delta `^f6g7h8`. Block ords differ from the ords of the chunks holding
/// them, except for Alpha.
fn small_blocks_day(fx: &mut Fx) -> String {
    let body = format!(
        "Alpha small block.\n\nBravo small block.\n\nCharlie small block.\n\n{}\n\n{}\n",
        big_block("Delta."),
        big_block("Echo."),
    );
    let d = fx.daily("2026-09-05", &body);
    let chunks = fx.chunks(&d);
    assert_eq!(chunks.len(), 3, "precondition: three chunks");
    assert!(
        chunks[0].content.contains("Alpha") && chunks[0].content.contains("Charlie"),
        "precondition: chunk 0 holds the three small blocks"
    );
    fx.pin_block(&d, 1, "b7k2m9");
    fx.pin_block(&d, 2, "c3d4e5");
    fx.pin_block(&d, 3, "f6g7h8");
    fx.embed_each(&d, &[q(), e(1), e(2)]);
    d
}

#[test]
fn a_transcluded_block_queries_with_the_chunk_whose_byte_range_holds_it_not_the_chunk_of_that_ord()
{
    let mut fx = new_vault();
    let _d = small_blocks_day(&mut fx);
    // Bravo is block 1 but lies in chunk 0; chunk 1 is Delta.
    let t = fx.topic("Jumping", "![[2026-09-05#^b7k2m9]]\n");
    let via_c0 = fx.plain("Via chunk 0", "Close to chunk 0.");
    let via_c1 = fx.plain("Via chunk 1", "Close to chunk 1.");
    let via_c2 = fx.plain("Via chunk 2", "Close to chunk 2.");
    fx.embed(&via_c0, &near(0, 3, 0.9));
    fx.embed(&via_c1, &near(1, 4, 0.9));
    fx.embed(&via_c2, &near(2, 5, 0.9));

    let got = fx.run_unembedded(&t);

    assert_eq!(ids(&got), vec![via_c0]);
}

#[test]
fn a_range_transclusion_queries_with_every_chunk_its_bytes_overlap_and_no_other() {
    let mut fx = new_vault();
    let _d = small_blocks_day(&mut fx);
    // Charlie (chunk 0) through Delta (chunk 1): chunk 2 is not touched.
    let t = fx.topic("Jumping", "![[2026-09-05#^c3d4e5..^f6g7h8]]\n");
    let via_c0 = fx.plain("Via chunk 0", "Close to chunk 0.");
    let via_c1 = fx.plain("Via chunk 1", "Close to chunk 1.");
    let via_c2 = fx.plain("Via chunk 2", "Close to chunk 2.");
    fx.embed(&via_c0, &near(0, 3, 0.9));
    fx.embed(&via_c1, &near(1, 4, 0.85));
    fx.embed(&via_c2, &near(2, 5, 0.95));

    let got = fx.run_unembedded(&t);

    assert_eq!(ids(&got), vec![via_c0, via_c1]);
}

#[test]
fn only_a_topic_notes_transclusions_give_query_vectors() {
    let mut fx = new_vault();
    let _d = small_blocks_day(&mut fx);
    let via_block = fx.plain("Via the day", "Close to the transcluded chunk.");
    fx.embed(&via_block, &near(0, 3, 0.9));

    // A plain note of nothing but a transclusion has no query vector.
    let only = fx.plain("Only a token", "![[2026-09-05#^b7k2m9]]\n");
    assert!(
        fx.chunks(&only).is_empty(),
        "precondition: the note has no chunks"
    );
    let got = fx.run_unembedded(&only);
    assert_eq!(got.reason, Some("empty_note"));
    assert!(got.echoes.is_empty());

    // A plain note with its own text and a transclusion queries with its own
    // chunk only.
    let mixed = fx.plain("Mixed", "Own words.\n\n![[2026-09-05#^b7k2m9]]\n");
    fx.embed(&mixed, &e(6));
    let via_own = fx.plain("Via own", "Close to the plain note's own chunk.");
    fx.embed(&via_own, &near(6, 7, 0.95));
    let got = fx.run_unembedded(&mixed);
    assert_eq!(got.reason, None);
    assert_eq!(ids(&got), vec![via_own]);
}

// ---------------------------------------------------------------- fix round 1: 64-text cap per chunk

#[test]
fn a_later_smaller_chunk_still_fits_after_an_earlier_chunk_overflowed() {
    let mut fx = new_vault();
    let o = open_plain(&mut fx, "Open");
    let mut table = TableEmbedder::new(DIM);
    let a = blocky(&mut fx, &mut table, "Alpha", 40, 17);
    let b = blocky(&mut fx, &mut table, "Beta", 30, 29);
    let g = blocky(&mut fx, &mut table, "Gamma", 10, 7);
    fx.embed(&a, &near(0, 1, 0.95));
    fx.embed(&b, &near(0, 2, 0.9));
    fx.embed(&g, &near(0, 4, 0.85));
    let rec = Recording::new(table);

    let got = fx.run(&rec, &o, LIMIT);

    assert_eq!(ids(&got), vec![a.clone(), b.clone(), g.clone()]);
    assert_eq!(the_echo(&got, &a).passage, "Alpha block 17");
    assert_eq!(the_echo(&got, &b).passage, "Beta block 00", "40 + 30 > 64");
    assert_eq!(
        the_echo(&got, &g).passage,
        "Gamma block 07",
        "40 + 10 fits in 64"
    );
    let batches = rec.batches();
    assert_eq!(batches.iter().map(Vec::len).sum::<usize>(), 50);
}

#[test]
fn the_text_cap_is_exact_one_over_is_skipped_and_a_later_chunk_landing_on_it_fits() {
    let mut fx = new_vault();
    let o = open_plain(&mut fx, "Open");
    let mut table = TableEmbedder::new(DIM);
    let a = blocky(&mut fx, &mut table, "Alpha", 40, 17);
    let b = blocky(&mut fx, &mut table, "Beta", 25, 20);
    let g = blocky(&mut fx, &mut table, "Gamma", 24, 11);
    fx.embed(&a, &near(0, 1, 0.95));
    fx.embed(&b, &near(0, 2, 0.9));
    fx.embed(&g, &near(0, 4, 0.85));
    let rec = Recording::new(table);

    let got = fx.run(&rec, &o, LIMIT);

    assert_eq!(ids(&got), vec![a.clone(), b.clone(), g.clone()]);
    assert_eq!(the_echo(&got, &a).passage, "Alpha block 17");
    assert_eq!(
        the_echo(&got, &b).passage,
        "Beta block 00",
        "40 + 25 = 65 is one over the cap"
    );
    assert_eq!(
        the_echo(&got, &g).passage,
        "Gamma block 11",
        "40 + 24 = 64 is exactly the cap, and Beta's skip did not stop the scan"
    );
    let batches = rec.batches();
    assert_eq!(batches.iter().map(Vec::len).sum::<usize>(), 64);
}

// ---------------------------------------------------------------- fix round 1: sentence sub-chunks

/// One paragraph of 200 sentences, joined by a space, a newline or two
/// spaces in turn, with a double space and a newline inside each sentence
/// and multibyte letters: far past the chunker's 600-token block limit, so
/// it is stored as sentence sub-chunks whose text is re-joined with single
/// spaces.
fn long_paragraph() -> String {
    const SEPS: [&str; 3] = [" ", "\n", "  "];
    let mut s = String::new();
    for i in 0..200 {
        if i > 0 {
            s.push_str(SEPS[i % 3]);
        }
        s.push_str(&format!(
            "Sentence {i:04} håș  two spaces and a\nline break."
        ));
    }
    s
}

fn squash(s: &str) -> String {
    s.split_whitespace().collect::<Vec<_>>().join(" ")
}

#[test]
fn a_sentence_sub_chunks_echo_starts_at_its_own_passage_in_the_body() {
    const INTRO: &str = "Intro paragraph.\n\n";
    let body = format!("{INTRO}{}", long_paragraph());
    for pick in 0..4 {
        let mut fx = new_vault();
        let o = open_plain(&mut fx, "Open");
        let c = fx.plain("Transcript", &body);
        let chunks = fx.chunks(&c);
        assert!(
            chunks.len() >= 6,
            "precondition: sub-chunks, got {}",
            chunks.len()
        );
        let idx = if pick == 3 {
            chunks.len() - 1
        } else {
            pick + 1
        };
        assert_eq!(
            chunks[idx].start_byte,
            Some(INTRO.len() as i64),
            "precondition: every sub-chunk carries the whole block's start"
        );
        let vectors: Vec<Vec<f32>> = (0..chunks.len())
            .map(|i| if i == idx { near(0, 1, 0.9) } else { e(5) })
            .collect();
        fx.embed_each(&c, &vectors);

        let got = fx.run_unembedded(&o);

        let echo = the_echo(&got, &c);
        let content = &chunks[idx].content;
        let first_sentence = &content[..content.find("break.").unwrap() + "break.".len()];
        let expected = body.find(first_sentence).unwrap();
        assert_eq!(echo.start_byte, Some(expected), "sub-chunk {idx}");
        assert!(
            body[expected..].starts_with(&echo.passage),
            "sub-chunk {idx}: {:?}",
            &echo.passage[..40]
        );
        assert_eq!(squash(&echo.passage), squash(content), "sub-chunk {idx}");
        assert_ne!(
            &echo.passage, content,
            "the fixture's separators make the stored text differ from the body's"
        );
    }
}

#[test]
fn a_sub_chunk_not_found_in_the_body_falls_back_to_its_range_start() {
    for (start, end) in [(5, 40), (500, 540)] {
        let mut fx = new_vault();
        let o = open_plain(&mut fx, "Open");
        let stale = fx.plain(
            "Stale",
            "Completely different body text that now sits where the chunk used to be.",
        );
        fx.clear_chunks(&stale);
        fx.raw_chunk(
            "01KSTALE0001",
            &stale,
            0,
            "Ghost sentence one. Ghost sentence two.",
            Some(&near(0, 1, 0.9)),
        );
        fx.conn()
            .execute(
                "UPDATE chunks SET start_byte = ?, end_byte = ? WHERE id = '01KSTALE0001'",
                params![start, end],
            )
            .unwrap();

        let got = fx.run_unembedded(&o);

        let echo = the_echo(&got, &stale);
        assert_eq!(echo.passage, "Ghost sentence one. Ghost sentence two.");
        assert_eq!(
            echo.start_byte,
            Some(start as usize),
            "range {start}..{end}"
        );
    }
}

// ---------------------------------------------------------------- fix round 1: zero vectors

#[test]
fn a_candidate_chunk_with_a_zero_vector_is_skipped_not_an_error() {
    let mut fx = new_vault();
    let o = open_plain(&mut fx, "Open");
    let zero = fx.plain("Zero", "A chunk whose stored vector is all zeros.");
    fx.embed(&zero, &[0.0; DIM]);
    let echo = fx.plain("Echo", "The valid echo.");
    fx.embed(&echo, &near(0, 2, 0.8));

    let got = fx.run_unembedded(&o);

    assert_eq!(ids(&got), vec![echo], "the zero-vector chunk has no score");
}

#[test]
fn an_open_note_chunk_with_a_zero_vector_is_a_query_that_finds_nothing() {
    let mut fx = new_vault();
    let o = fx.plain("Open", "Placeholder.");
    fx.clear_chunks(&o);
    fx.raw_chunk("01KOPENZERO001", &o, 0, "zero own", Some(&[0.0; DIM]));
    fx.raw_chunk("01KOPENREAL001", &o, 1, "real own", Some(&q()));
    let echo = fx.plain("Echo", "The valid echo.");
    fx.embed(&echo, &near(0, 2, 0.8));

    let got = fx.run_unembedded(&o);

    assert_eq!(got.reason, None);
    assert_eq!(ids(&got), vec![echo]);
}
