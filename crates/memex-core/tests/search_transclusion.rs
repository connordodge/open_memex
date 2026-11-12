//! WI #15 (R12): search through transclusions with chunk byte ranges.
//!
//! - D25: the indexer stores each chunk's UTF-8 byte range in
//!   `chunks.start_byte` / `end_byte`; after fusion, `search` expands every
//!   daily-note hit into the topic notes whose `from-day` transclusion covers
//!   a block overlapping the hit chunk's range. Expanded hits carry
//!   `via: "<date>"`, sit immediately after their source hit with the same
//!   score, appear at most once per (topic note, date) and never push the
//!   total past `k`. NULL ranges never expand.
//! - Spec TD5: no transcluded text is indexed; a topic note's own chunks hold
//!   the `![[…]]` token text.
//! - Overlap: block `[s, e)` overlaps chunk `[cs, ce)` iff `s < ce && cs < e`.
//!
//! Real SQLite, real schema V5, temp vaults only, no real embedding model
//! (FTS mode, or the `FakeEmbedder` for hybrid).

use std::collections::BTreeSet;

use memex_core::chunker;
use memex_core::embedder::{Embedder, FakeEmbedder};
use memex_core::excerpts::add_excerpt;
use memex_core::indexer;
use memex_core::notes::{
    create_note_as, get_note, update_note_as, CreateNote, Note, NoteId, RenameOptions, UpdateNote,
};
use memex_core::search::{
    search, SearchFilters, SearchHit, SearchMode, SearchOptions, SearchResults,
};
use memex_core::{Caller, Vault};
use rusqlite::params;
use serde_json::{json, Value};
use tempfile::TempDir;

// ---------------------------------------------------------------------------
// Fixtures
// ---------------------------------------------------------------------------

const DAY: &str = "2026-09-05";
const DAY2: &str = "2026-09-06";

/// The C4 render-fixture daily note: blocks (0, b7k2m9), (1, c3d4e5),
/// (2, f6g7h8). Small: the whole person section is one chunk.
const DAY_BODY: &str = "Fixed the jump arc.\n\n- tried coyote time\n\nSleep was bad.\n";
const IDS: [&str; 3] = ["b7k2m9", "c3d4e5", "f6g7h8"];

/// `n` filler words that no test queries for.
fn filler(n: usize) -> String {
    const WORDS: [&str; 5] = ["lorem", "ipsum", "dolor", "sit", "amet"];
    (0..n)
        .map(|i| WORDS[i % WORDS.len()])
        .collect::<Vec<_>>()
        .join(" ")
}

/// A daily body whose three blocks are each big enough to be their own
/// chunk, so chunk 0 holds only block b7k2m9, chunk 1 only c3d4e5 and
/// chunk 2 only f6g7h8. The prefix has multibyte text before every block.
fn long_day_body() -> String {
    let f = filler(260);
    format!(
        "Café ☕ fixed the jump arc quasar. {f}\n\n\
         Naïve 🎉 tried coyote time. {f}\n\n\
         Zoë 😀 sleep was bad quasar. {f}\n"
    )
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn fresh_vault() -> (TempDir, Vault) {
    let dir = tempfile::tempdir().unwrap();
    let vault = Vault::create(dir.path()).unwrap();
    (dir, vault)
}

fn reindex_with(vault: &mut Vault, note: &Note, embedder: Option<&dyn Embedder>) {
    indexer::reindex_note(
        vault.connection_mut(),
        note.id.as_str(),
        &note.content_md,
        embedder,
    )
    .unwrap();
}

fn create_with(
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
    reindex_with(vault, &note, embedder);
    note
}

fn create_plain(vault: &mut Vault, title: &str, body: &str) -> Note {
    create_with(vault, title, body, None, None)
}

fn create_daily(vault: &mut Vault, date: &str, body: &str) -> Note {
    create_with(vault, date, body, Some(json!({ "role": "daily" })), None)
}

fn create_topic(vault: &mut Vault, title: &str, body: &str) -> Note {
    create_with(vault, title, body, Some(json!({ "role": "topic" })), None)
}

/// Person update of a note body, then reindex from the saved note (D8).
fn set_body(vault: &mut Vault, id: &NoteId, body: &str) -> Note {
    let version = get_note(vault, id).unwrap().version;
    let saved = update_note_as(
        vault,
        id,
        version,
        UpdateNote {
            content_md: Some(body.into()),
            ..Default::default()
        },
        RenameOptions::default(),
        Caller::Person,
    )
    .unwrap_or_else(|e| panic!("update {id}: {e}"));
    reindex_with(vault, &saved, None);
    saved
}

/// `(ord, block_id, start_byte, end_byte, text)` of a note's blocks.
fn blocks_of(vault: &Vault, id: &NoteId) -> Vec<(i64, String, i64, i64, String)> {
    let conn = vault.connection_ref();
    let mut stmt = conn
        .prepare(
            "SELECT ord, block_id, start_byte, end_byte, text FROM blocks
             WHERE note_id = ? ORDER BY ord",
        )
        .unwrap();
    stmt.query_map([id.as_str()], |r| {
        Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?, r.get(4)?))
    })
    .unwrap()
    .collect::<Result<_, _>>()
    .unwrap()
}

/// Pins the stored block ids of a three-block daily note to the C4 ids.
fn pin_ids(vault: &Vault, note: &Note) {
    let blocks = blocks_of(vault, &note.id);
    assert_eq!(blocks.len(), 3, "precondition: the day has three blocks");
    for (ord, id) in IDS.iter().enumerate() {
        let n = vault
            .connection_ref()
            .execute(
                "UPDATE blocks SET block_id = ? WHERE note_id = ? AND ord = ?",
                params![id, note.id.as_str(), ord as i64],
            )
            .unwrap();
        assert_eq!(n, 1, "pin block {ord}");
    }
}

/// The C4 fixture day with pinned block ids.
fn fixture_day(vault: &mut Vault) -> Note {
    let day = create_daily(vault, DAY, DAY_BODY);
    pin_ids(vault, &day);
    day
}

/// The three-chunk day with pinned block ids.
fn long_day(vault: &mut Vault) -> Note {
    let day = create_daily(vault, DAY, &long_day_body());
    pin_ids(vault, &day);
    let chunk_count: i64 = vault
        .connection_ref()
        .query_row(
            "SELECT COUNT(*) FROM chunks WHERE note_id = ?",
            [day.id.as_str()],
            |r| r.get(0),
        )
        .unwrap();
    assert_eq!(chunk_count, 3, "precondition: one chunk per block");
    day
}

/// `(ord, content, start_byte, end_byte)` of a note's stored chunks.
fn chunk_rows(vault: &Vault, id: &NoteId) -> Vec<(i64, String, Option<i64>, Option<i64>)> {
    let conn = vault.connection_ref();
    let mut stmt = conn
        .prepare(
            "SELECT ord, content, start_byte, end_byte FROM chunks
             WHERE note_id = ? ORDER BY ord",
        )
        .unwrap();
    stmt.query_map([id.as_str()], |r| {
        Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?))
    })
    .unwrap()
    .collect::<Result<_, _>>()
    .unwrap()
}

/// Overwrites the byte range of every chunk of `id`.
fn set_chunk_range(vault: &Vault, id: &NoteId, start: Option<i64>, end: Option<i64>) {
    let n = vault
        .connection_ref()
        .execute(
            "UPDATE chunks SET start_byte = ?, end_byte = ? WHERE note_id = ?",
            params![start, end, id.as_str()],
        )
        .unwrap();
    assert!(n > 0, "precondition: the note has chunks");
}

fn fts(vault: &Vault, query: &str, k: usize) -> Vec<SearchHit> {
    search(
        vault.connection_ref(),
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

/// `(note_title, via)` per hit, in order.
fn summary(hits: &[SearchHit]) -> Vec<(String, Option<String>)> {
    hits.iter()
        .map(|h| (h.note_title.clone(), h.via.clone()))
        .collect()
}

fn direct(title: &str) -> (String, Option<String>) {
    (title.to_string(), None)
}

fn via(title: &str, date: &str) -> (String, Option<String>) {
    (title.to_string(), Some(date.to_string()))
}

/// Every expanded hit sits right after a hit on the daily note of its date
/// (several topics expanding one source hit follow it one after another),
/// and carries that hit's score. The source hit itself has no `via`.
fn assert_expanded_hits_follow_their_source(hits: &[SearchHit]) {
    for (i, h) in hits.iter().enumerate() {
        let Some(date) = &h.via else { continue };
        let source = hits[..i]
            .iter()
            .rev()
            .find(|p| p.via.is_none())
            .unwrap_or_else(|| panic!("expanded hit {i} has no source hit before it"));
        assert_eq!(
            (source.note_title.as_str(), source.via.as_deref()),
            (date.as_str(), None),
            "expanded hit {i} ({} via {date}) must directly follow a hit on daily note {date}: {:?}",
            h.note_title,
            summary(hits)
        );
        assert_eq!(
            h.score, source.score,
            "expanded hit {i} must carry its source hit score"
        );
    }
}

// ---------------------------------------------------------------------------
// AC 4: the indexer stores chunk byte ranges
// ---------------------------------------------------------------------------

#[test]
fn reindex_stores_each_chunk_start_and_end_byte() {
    let (_d, mut vault) = fresh_vault();
    let body = format!(
        "Café ☕ intro. {}\n\nNaïve 🎉 middle. {}\n\nZoë 😀 tail.",
        filler(280),
        filler(280)
    );
    let note = create_plain(&mut vault, "Multibyte note", &body);
    let stored = get_note(&vault, &note.id).unwrap().content_md;

    let rows = chunk_rows(&vault, &note.id);
    let expected: Vec<(i64, String, Option<i64>, Option<i64>)> = chunker::chunk(&stored)
        .into_iter()
        .map(|c| {
            (
                c.ord,
                c.content,
                Some(c.start_byte as i64),
                Some(c.end_byte as i64),
            )
        })
        .collect();
    assert!(rows.len() >= 2, "precondition: several chunks");
    assert_eq!(
        rows, expected,
        "stored chunk rows must carry the chunker's ranges"
    );
    for (ord, content, start, end) in &rows {
        let (s, e) = (
            start.expect("start_byte set") as usize,
            end.expect("end_byte set") as usize,
        );
        let slice = stored
            .get(s..e)
            .unwrap_or_else(|| panic!("chunk {ord} range {s}..{e} is not a valid byte range"));
        assert!(
            slice.contains(content.as_str()),
            "chunk {ord} slice {slice:?}"
        );
    }
}

#[test]
fn reindex_after_an_edit_replaces_the_stored_byte_ranges() {
    let (_d, mut vault) = fresh_vault();
    let note = create_plain(&mut vault, "Edited note", "Short first version.");
    let first = chunk_rows(&vault, &note.id);
    assert_eq!(first.len(), 1);
    assert_eq!(first[0].2, Some(0), "first version starts at byte 0");

    let body = format!("😀😀 Prefix line.\n\n{}\n\nSecond version.", filler(290));
    let saved = set_body(&mut vault, &note.id, &body);
    let rows = chunk_rows(&vault, &note.id);
    let expected: Vec<(i64, String, Option<i64>, Option<i64>)> = chunker::chunk(&saved.content_md)
        .into_iter()
        .map(|c| {
            (
                c.ord,
                c.content,
                Some(c.start_byte as i64),
                Some(c.end_byte as i64),
            )
        })
        .collect();
    assert_eq!(rows, expected);
    assert!(
        rows.iter().all(|r| r.3.unwrap_or(0) > 0),
        "every chunk has a non-empty stored range"
    );
}

#[test]
fn daily_note_chunk_ranges_line_up_with_its_block_ranges() {
    let (_d, mut vault) = fresh_vault();
    let day = long_day(&mut vault);
    let blocks = blocks_of(&vault, &day.id);
    let chunks = chunk_rows(&vault, &day.id);
    assert_eq!(chunks.len(), blocks.len());
    for ((_, id, s, e, _), (ord, _, cs, ce)) in blocks.iter().zip(&chunks) {
        let (cs, ce) = (cs.expect("start_byte set"), ce.expect("end_byte set"));
        assert!(
            *s < ce && cs < *e,
            "chunk {ord} {cs}..{ce} must overlap its block {id} {s}..{e}"
        );
        for (_, other, os, oe, _) in &blocks {
            if other != id {
                assert!(
                    !(*os < ce && cs < *oe),
                    "chunk {ord} {cs}..{ce} must not overlap block {other} {os}..{oe}"
                );
            }
        }
    }
}

// ---------------------------------------------------------------------------
// AC 5: a daily-note hit is followed by the transcluding topic, via <date>
// ---------------------------------------------------------------------------

#[test]
fn daily_block_hit_is_followed_by_the_transcluding_topic_with_via_date() {
    let (_d, mut vault) = fresh_vault();
    let day = fixture_day(&mut vault);
    let topic = create_topic(
        &mut vault,
        "Player Loop",
        "Loop notes.\n\n![[2026-09-05#^b7k2m9]]\n",
    );

    let hits = fts(&vault, "jump", 10);
    assert_eq!(
        summary(&hits),
        vec![direct(DAY), via("Player Loop", DAY)],
        "daily hit first, then the topic via the date"
    );
    assert_eq!(hits[0].note_id, day.id.as_str());
    assert_eq!(hits[0].via, None, "the daily-note hit itself has no via");
    assert_eq!(hits[1].note_id, topic.id.as_str());
    assert_eq!(hits[1].via.as_deref(), Some("2026-09-05"));
    assert_eq!(hits[1].score, hits[0].score, "same score as its source hit");
}

#[test]
fn expansion_works_when_multibyte_text_precedes_the_matched_block() {
    let (_d, mut vault) = fresh_vault();
    long_day(&mut vault);
    create_topic(
        &mut vault,
        "Sleep Log",
        "Nights.\n\n![[2026-09-05#^f6g7h8]]\n",
    );

    let hits = fts(&vault, "sleep", 10);
    assert_eq!(summary(&hits), vec![direct(DAY), via("Sleep Log", DAY)]);
}

#[test]
fn expanded_hits_sit_directly_after_their_source_hit_with_the_same_score() {
    let (_d, mut vault) = fresh_vault();
    // Day A matches strongly, a plain note in between, day B weakly.
    let a = create_daily(
        &mut vault,
        DAY,
        "Jump jump jump.\n\n- tried coyote time\n\nSleep was bad.\n",
    );
    pin_ids(&vault, &a);
    create_plain(
        &mut vault,
        "Jump Physics",
        &format!("A jump is a parabola. {}", filler(40)),
    );
    let b_body = format!("One jump today. {}\n", filler(120));
    let b = create_daily(&mut vault, DAY2, &b_body);
    let b_block = blocks_of(&vault, &b.id)[0].1.clone();
    create_topic(&mut vault, "Player Loop", "![[2026-09-05#^b7k2m9]]\n");
    create_topic(
        &mut vault,
        "Daily Jumps",
        &format!("![[2026-09-06#^{b_block}]]\n"),
    );

    let hits = fts(&vault, "jump", 10);
    let s = summary(&hits);
    assert_eq!(hits.len(), 5, "3 direct hits + 2 expanded hits, got {s:?}");
    assert!(s.contains(&via("Player Loop", DAY)), "{s:?}");
    assert!(s.contains(&via("Daily Jumps", DAY2)), "{s:?}");
    assert!(s.contains(&direct("Jump Physics")), "{s:?}");
    assert_expanded_hits_follow_their_source(&hits);
    for pair in hits.windows(2) {
        assert!(
            pair[0].score >= pair[1].score,
            "hits must stay in score order: {s:?}"
        );
    }
}

#[test]
fn edited_daily_block_still_expands_to_the_topic_without_reindexing_the_topic() {
    let (_d, mut vault) = fresh_vault();
    let day = fixture_day(&mut vault);
    create_topic(
        &mut vault,
        "Player Loop",
        "Loop notes.\n\n![[2026-09-05#^b7k2m9]]\n",
    );

    set_body(
        &mut vault,
        &day.id,
        "Fixed the quokka arc.\n\n- tried coyote time\n\nSleep was bad.\n",
    );
    let blocks = blocks_of(&vault, &day.id);
    assert_eq!(
        (blocks[0].1.as_str(), blocks[0].4.as_str()),
        ("b7k2m9", "Fixed the quokka arc."),
        "precondition: the edited block keeps its id"
    );

    assert_eq!(
        summary(&fts(&vault, "quokka", 10)),
        vec![direct(DAY), via("Player Loop", DAY)],
        "the new block text is found through the topic"
    );
    assert!(
        fts(&vault, "jump", 10).is_empty(),
        "the old block text is no longer found anywhere"
    );
}

#[test]
fn hybrid_search_with_fake_embedder_expands_daily_hits() {
    let (_d, mut vault) = fresh_vault();
    let emb = FakeEmbedder::new(64);
    let day = create_with(
        &mut vault,
        DAY,
        DAY_BODY,
        Some(json!({ "role": "daily" })),
        Some(&emb),
    );
    pin_ids(&vault, &day);
    create_with(
        &mut vault,
        "Player Loop",
        "Loop notes.\n\n![[2026-09-05#^b7k2m9]]\n",
        Some(json!({ "role": "topic" })),
        Some(&emb),
    );

    let hits = search(
        vault.connection_ref(),
        SearchOptions {
            query: "jump",
            k: 10,
            mode: SearchMode::Hybrid,
            filters: SearchFilters::default(),
            embedder: Some(&emb),
        },
    )
    .unwrap()
    .hits;
    let s = summary(&hits);
    let expanded: Vec<_> = s
        .iter()
        .filter(|h| **h == via("Player Loop", DAY))
        .collect();
    assert_eq!(expanded.len(), 1, "one Player Loop hit via the day: {s:?}");
    assert_expanded_hits_follow_their_source(&hits);
}

// ---------------------------------------------------------------------------
// AC 6: a non-overlapping block of the same day is not added
// ---------------------------------------------------------------------------

#[test]
fn topic_transcluding_a_non_overlapping_block_of_the_same_day_is_not_added() {
    let (_d, mut vault) = fresh_vault();
    long_day(&mut vault);
    create_topic(&mut vault, "Player Loop", "![[2026-09-05#^b7k2m9]]\n");
    create_topic(&mut vault, "Coyote Notes", "![[2026-09-05#^c3d4e5]]\n");
    create_topic(&mut vault, "Sleep Log", "![[2026-09-05#^f6g7h8]]\n");

    assert_eq!(
        summary(&fts(&vault, "jump", 10)),
        vec![direct(DAY), via("Player Loop", DAY)]
    );
    assert_eq!(
        summary(&fts(&vault, "coyote", 10)),
        vec![direct(DAY), via("Coyote Notes", DAY)]
    );
}

/// The fixture day as one chunk, a topic on block c3d4e5, and that block's
/// byte range.
fn boundary_setup(vault: &mut Vault) -> (Note, i64, i64) {
    let day = fixture_day(vault);
    create_topic(vault, "Coyote Notes", "![[2026-09-05#^c3d4e5]]\n");
    let blocks = blocks_of(vault, &day.id);
    let (s, e) = (blocks[1].2, blocks[1].3);
    assert_eq!(
        &vault_text(vault, &day.id)[s as usize..e as usize],
        "- tried coyote time"
    );
    assert_eq!(
        summary(&fts(vault, "jump", 10)),
        vec![direct(DAY), via("Coyote Notes", DAY)],
        "precondition: the stored whole-day chunk range overlaps the block"
    );
    (day, s, e)
}

fn vault_text(vault: &Vault, id: &NoteId) -> String {
    get_note(vault, id).unwrap().content_md
}

#[test]
fn chunk_ending_exactly_where_the_block_starts_does_not_overlap() {
    let (_d, mut vault) = fresh_vault();
    let (day, s, _e) = boundary_setup(&mut vault);
    set_chunk_range(&vault, &day.id, Some(0), Some(s));
    assert_eq!(summary(&fts(&vault, "jump", 10)), vec![direct(DAY)]);
}

#[test]
fn chunk_starting_exactly_where_the_block_ends_does_not_overlap() {
    let (_d, mut vault) = fresh_vault();
    let (day, _s, e) = boundary_setup(&mut vault);
    let len = vault_text(&vault, &day.id).len() as i64;
    set_chunk_range(&vault, &day.id, Some(e), Some(len));
    assert_eq!(summary(&fts(&vault, "jump", 10)), vec![direct(DAY)]);
}

#[test]
fn chunk_overlapping_the_first_byte_of_the_block_expands() {
    let (_d, mut vault) = fresh_vault();
    let (day, s, _e) = boundary_setup(&mut vault);
    set_chunk_range(&vault, &day.id, Some(0), Some(s + 1));
    assert_eq!(
        summary(&fts(&vault, "jump", 10)),
        vec![direct(DAY), via("Coyote Notes", DAY)]
    );
}

#[test]
fn chunk_overlapping_the_last_byte_of_the_block_expands() {
    let (_d, mut vault) = fresh_vault();
    let (day, _s, e) = boundary_setup(&mut vault);
    let len = vault_text(&vault, &day.id).len() as i64;
    set_chunk_range(&vault, &day.id, Some(e - 1), Some(len));
    assert_eq!(
        summary(&fts(&vault, "jump", 10)),
        vec![direct(DAY), via("Coyote Notes", DAY)]
    );
}

// ---------------------------------------------------------------------------
// AC 7: range transclusions cover their middle blocks
// ---------------------------------------------------------------------------

#[test]
fn range_transclusion_expands_a_hit_on_its_middle_block() {
    let (_d, mut vault) = fresh_vault();
    long_day(&mut vault);
    create_topic(&mut vault, "Player Loop", "![[2026-09-05#^b7k2m9]]\n");
    create_topic(
        &mut vault,
        "Arc Review",
        "Whole day:\n\n![[2026-09-05#^b7k2m9..^f6g7h8]]\n",
    );

    assert_eq!(
        summary(&fts(&vault, "coyote", 10)),
        vec![direct(DAY), via("Arc Review", DAY)]
    );
}

#[test]
fn reversed_range_transclusion_expands_a_hit_on_its_middle_block() {
    let (_d, mut vault) = fresh_vault();
    long_day(&mut vault);
    create_topic(
        &mut vault,
        "Arc Review",
        "![[2026-09-05#^f6g7h8..^b7k2m9]]\n",
    );

    assert_eq!(
        summary(&fts(&vault, "coyote", 10)),
        vec![direct(DAY), via("Arc Review", DAY)]
    );
}

#[test]
fn range_endpoints_are_inclusive_and_bound_the_expansion() {
    let (_d, mut vault) = fresh_vault();
    long_day(&mut vault);
    create_topic(
        &mut vault,
        "Front Half",
        "![[2026-09-05#^b7k2m9..^c3d4e5]]\n",
    );
    create_topic(
        &mut vault,
        "Back Half",
        "![[2026-09-05#^c3d4e5..^f6g7h8]]\n",
    );

    assert_eq!(
        summary(&fts(&vault, "jump", 10)),
        vec![direct(DAY), via("Front Half", DAY)],
        "block 0 is only in the front half"
    );
    assert_eq!(
        summary(&fts(&vault, "sleep", 10)),
        vec![direct(DAY), via("Back Half", DAY)],
        "block 2 is only in the back half"
    );
    let coyote = summary(&fts(&vault, "coyote", 10));
    assert_eq!(coyote.len(), 3, "block 1 is in both halves: {coyote:?}");
    assert_eq!(coyote[0], direct(DAY));
    let topics: BTreeSet<_> = coyote[1..].iter().cloned().collect();
    assert_eq!(
        topics,
        BTreeSet::from([via("Back Half", DAY), via("Front Half", DAY)])
    );
}

// ---------------------------------------------------------------------------
// AC 8: a transclusion whose endpoint block is gone does not expand
// ---------------------------------------------------------------------------

#[test]
fn range_whose_end_block_no_longer_exists_does_not_expand() {
    let (_d, mut vault) = fresh_vault();
    let day = fixture_day(&mut vault);
    create_topic(
        &mut vault,
        "Arc Review",
        "![[2026-09-05#^b7k2m9..^f6g7h8]]\n",
    );
    assert_eq!(
        summary(&fts(&vault, "jump", 10)),
        vec![direct(DAY), via("Arc Review", DAY)],
        "precondition: the range expands while both endpoints exist"
    );

    set_body(
        &mut vault,
        &day.id,
        "Fixed the jump arc.\n\n- tried coyote time\n",
    );
    let ids: Vec<String> = blocks_of(&vault, &day.id)
        .into_iter()
        .map(|b| b.1)
        .collect();
    assert_eq!(
        ids,
        vec!["b7k2m9", "c3d4e5"],
        "precondition: f6g7h8 is gone"
    );

    assert_eq!(summary(&fts(&vault, "jump", 10)), vec![direct(DAY)]);
    assert_eq!(summary(&fts(&vault, "coyote", 10)), vec![direct(DAY)]);
}

#[test]
fn range_whose_start_block_does_not_exist_does_not_expand() {
    let (_d, mut vault) = fresh_vault();
    fixture_day(&mut vault);
    create_topic(
        &mut vault,
        "Ghost Range",
        "![[2026-09-05#^gone11..^c3d4e5]]\n",
    );
    create_topic(&mut vault, "Coyote Notes", "![[2026-09-05#^c3d4e5]]\n");

    assert_eq!(
        summary(&fts(&vault, "coyote", 10)),
        vec![direct(DAY), via("Coyote Notes", DAY)]
    );
}

#[test]
fn removed_block_stub_creates_no_hits() {
    let (_d, mut vault) = fresh_vault();
    let day = fixture_day(&mut vault);
    let topic = create_topic(
        &mut vault,
        "Sleep Log",
        "Nights.\n\n![[2026-09-05#^f6g7h8]]\n",
    );
    assert_eq!(
        summary(&fts(&vault, "sleep", 10)),
        vec![direct(DAY), via("Sleep Log", DAY)],
        "precondition: the block is found through the topic"
    );

    set_body(
        &mut vault,
        &day.id,
        "Fixed the jump arc.\n\n- tried coyote time\n",
    );
    // The topic renders the stub now; reindexing it must not index the stub.
    let topic = get_note(&vault, &topic.id).unwrap();
    reindex_with(&mut vault, &topic, None);

    assert!(
        fts(&vault, "sleep", 10).is_empty(),
        "the removed text is gone"
    );
    assert!(
        fts(&vault, "removed", 10).is_empty(),
        "the `removed from <date>` stub is not searchable"
    );
    assert_eq!(
        summary(&fts(&vault, "jump", 10)),
        vec![direct(DAY)],
        "the topic does not expand from the remaining blocks"
    );
}

// ---------------------------------------------------------------------------
// AC 9: NULL ranges never expand
// ---------------------------------------------------------------------------

#[test]
fn chunks_with_null_byte_ranges_never_expand() {
    let (_d, mut vault) = fresh_vault();
    let day = fixture_day(&mut vault);
    create_topic(&mut vault, "Player Loop", "![[2026-09-05#^b7k2m9]]\n");
    assert_eq!(
        summary(&fts(&vault, "jump", 10)),
        vec![direct(DAY), via("Player Loop", DAY)],
        "precondition: the hit expands with a stored range"
    );

    set_chunk_range(&vault, &day.id, None, None);
    assert_eq!(summary(&fts(&vault, "jump", 10)), vec![direct(DAY)]);
}

#[test]
fn chunk_with_one_null_byte_bound_never_expands() {
    let (_d, mut vault) = fresh_vault();
    let day = fixture_day(&mut vault);
    create_topic(&mut vault, "Player Loop", "![[2026-09-05#^b7k2m9]]\n");
    let len = vault_text(&vault, &day.id).len() as i64;

    set_chunk_range(&vault, &day.id, None, Some(len));
    assert_eq!(summary(&fts(&vault, "jump", 10)), vec![direct(DAY)]);
    set_chunk_range(&vault, &day.id, Some(0), None);
    assert_eq!(summary(&fts(&vault, "jump", 10)), vec![direct(DAY)]);
    set_chunk_range(&vault, &day.id, Some(0), Some(len));
    assert_eq!(
        summary(&fts(&vault, "jump", 10)),
        vec![direct(DAY), via("Player Loop", DAY)],
        "a full range expands again"
    );
}

// ---------------------------------------------------------------------------
// AC 10: topic chunks hold the token text, not the transcluded text
// ---------------------------------------------------------------------------

#[test]
fn topic_chunks_hold_the_token_text_not_the_transcluded_block_text() {
    let (_d, mut vault) = fresh_vault();
    fixture_day(&mut vault);
    // The token shares a block with prose: a transclusion-only block is in
    // no chunk (WI #418, Spec #391 req 2).
    let topic = create_topic(
        &mut vault,
        "Player Loop",
        "Loop notes. ![[2026-09-05#^b7k2m9]]\n",
    );

    let rows = chunk_rows(&vault, &topic.id);
    assert!(!rows.is_empty());
    let all: String = rows.iter().map(|r| r.1.as_str()).collect();
    assert!(
        all.contains("![[2026-09-05#^b7k2m9]]"),
        "token text kept: {all:?}"
    );
    assert!(!all.contains("jump"), "block text not indexed: {all:?}");

    let own_matches: i64 = vault
        .connection_ref()
        .query_row(
            "SELECT COUNT(*) FROM chunk_fts WHERE chunk_fts MATCH '\"jump\"' AND note_id = ?",
            [topic.id.as_str()],
            |r| r.get(0),
        )
        .unwrap();
    assert_eq!(
        own_matches, 0,
        "the topic's own chunks do not match the block word"
    );

    let topic_hits: Vec<_> = fts(&vault, "jump", 10)
        .into_iter()
        .filter(|h| h.note_id == topic.id.as_str())
        .collect();
    assert_eq!(topic_hits.len(), 1, "the topic is found once");
    assert_eq!(
        topic_hits[0].via.as_deref(),
        Some(DAY),
        "and only through the transclusion"
    );
}

#[test]
fn topic_own_words_are_still_found_directly() {
    let (_d, mut vault) = fresh_vault();
    fixture_day(&mut vault);
    create_topic(
        &mut vault,
        "Player Loop",
        "Loop notes on momentum.\n\n![[2026-09-05#^b7k2m9]]\n",
    );

    assert_eq!(
        summary(&fts(&vault, "momentum", 10)),
        vec![direct("Player Loop")]
    );
    assert_eq!(
        summary(&fts(&vault, "jump", 10)),
        vec![direct(DAY), via("Player Loop", DAY)]
    );
}

// ---------------------------------------------------------------------------
// AC 11: one expanded hit per (topic, date); never more than k hits
// ---------------------------------------------------------------------------

#[test]
fn each_topic_and_date_pair_is_expanded_at_most_once() {
    let (_d, mut vault) = fresh_vault();
    long_day(&mut vault);
    create_topic(
        &mut vault,
        "Both Ends",
        "![[2026-09-05#^b7k2m9]]\n\n![[2026-09-05#^f6g7h8]]\n\n![[2026-09-05#^b7k2m9]]\n",
    );

    let hits = fts(&vault, "quasar", 10);
    let s = summary(&hits);
    assert_eq!(
        s.iter().filter(|h| **h == direct(DAY)).count(),
        2,
        "precondition: two daily chunks match: {s:?}"
    );
    assert_eq!(
        s.iter().filter(|h| **h == via("Both Ends", DAY)).count(),
        1,
        "one expanded hit for (Both Ends, {DAY}): {s:?}"
    );
    assert_eq!(s.len(), 3, "{s:?}");
    assert_eq!(
        s[1],
        via("Both Ends", DAY),
        "placed after the first source hit: {s:?}"
    );
    assert_expanded_hits_follow_their_source(&hits);
}

#[test]
fn a_topic_transcluding_two_days_gets_one_expanded_hit_per_day() {
    let (_d, mut vault) = fresh_vault();
    fixture_day(&mut vault);
    let b = create_daily(&mut vault, DAY2, "Another jump today.\n");
    let b_block = blocks_of(&vault, &b.id)[0].1.clone();
    create_topic(
        &mut vault,
        "Player Loop",
        &format!("![[2026-09-05#^b7k2m9]]\n\n![[2026-09-06#^{b_block}]]\n"),
    );

    let hits = fts(&vault, "jump", 10);
    let s = summary(&hits);
    let expanded: BTreeSet<_> = s.iter().filter(|h| h.1.is_some()).cloned().collect();
    assert_eq!(
        expanded,
        BTreeSet::from([via("Player Loop", DAY), via("Player Loop", DAY2)]),
        "{s:?}"
    );
    assert_eq!(s.len(), 4, "{s:?}");
    assert_expanded_hits_follow_their_source(&hits);
}

#[test]
fn expansion_never_pushes_the_total_past_k() {
    let (_d, mut vault) = fresh_vault();
    fixture_day(&mut vault);
    for title in ["Topic A", "Topic B", "Topic C"] {
        create_topic(&mut vault, title, "![[2026-09-05#^b7k2m9]]\n");
    }

    let one = fts(&vault, "jump", 1);
    assert_eq!(
        summary(&one),
        vec![direct(DAY)],
        "k = 1 keeps only the source hit"
    );

    let two = fts(&vault, "jump", 2);
    assert_eq!(two.len(), 2);
    assert_eq!(summary(&two)[0], direct(DAY));
    assert_eq!(two[1].via.as_deref(), Some(DAY));

    assert_eq!(fts(&vault, "jump", 3).len(), 3);

    let all = fts(&vault, "jump", 10);
    let s = summary(&all);
    assert_eq!(s.len(), 4, "{s:?}");
    assert_eq!(s[0], direct(DAY));
    let topics: BTreeSet<_> = s[1..].iter().cloned().collect();
    assert_eq!(
        topics,
        BTreeSet::from([
            via("Topic A", DAY),
            via("Topic B", DAY),
            via("Topic C", DAY)
        ])
    );
}

#[test]
fn expansion_is_capped_at_k_when_several_direct_hits_follow() {
    let (_d, mut vault) = fresh_vault();
    fixture_day(&mut vault);
    create_topic(&mut vault, "Player Loop", "![[2026-09-05#^b7k2m9]]\n");
    for i in 0..4 {
        create_plain(
            &mut vault,
            &format!("Jump note {i}"),
            &format!("A jump note. {}", filler(60 + i * 20)),
        );
    }
    for k in 1..=6 {
        let hits = fts(&vault, "jump", k);
        assert!(hits.len() <= k, "k = {k} gave {} hits", hits.len());
    }
    assert_eq!(
        fts(&vault, "jump", 6).len(),
        6,
        "5 direct hits + 1 expanded"
    );
}

// ---------------------------------------------------------------------------
// AC 12: `via` is serialized only on expanded hits
// ---------------------------------------------------------------------------

#[test]
fn serialized_search_results_have_a_via_key_only_on_expanded_hits() {
    let (_d, mut vault) = fresh_vault();
    fixture_day(&mut vault);
    create_topic(&mut vault, "Player Loop", "![[2026-09-05#^b7k2m9]]\n");
    create_plain(&mut vault, "Jump Physics", "A jump is a parabola.");

    let results = search(
        vault.connection_ref(),
        SearchOptions {
            query: "jump",
            k: 10,
            mode: SearchMode::Fts,
            filters: SearchFilters::default(),
            embedder: None,
        },
    )
    .unwrap();
    let json = serde_json::to_value(&results).unwrap();
    let hits = json["hits"].as_array().expect("hits array");
    assert_eq!(hits.len(), 3, "{json}");

    let base: BTreeSet<&str> = BTreeSet::from([
        "chunk_id",
        "note_id",
        "note_title",
        "snippet",
        "score",
        "ord",
    ]);
    let mut with_via = 0;
    for h in hits {
        let keys: BTreeSet<&str> = h.as_object().unwrap().keys().map(String::as_str).collect();
        if h["note_title"] == "Player Loop" {
            with_via += 1;
            assert_eq!(h["via"], json!("2026-09-05"), "{h}");
            let mut expected = base.clone();
            expected.insert("via");
            assert_eq!(keys, expected, "expanded hit keys: {h}");
        } else {
            assert_eq!(keys, base, "a direct hit has exactly the old keys: {h}");
        }
    }
    assert_eq!(with_via, 1, "{json}");

    // Hits without the key (as older payloads have them) read back as `None`
    // and serialize to the same JSON.
    let back: SearchResults = serde_json::from_value(json.clone()).unwrap();
    assert_eq!(
        back.hits.iter().filter(|h| h.via.is_none()).count(),
        2,
        "{json}"
    );
    assert_eq!(serde_json::to_value(&back).unwrap(), json);
}

// ---------------------------------------------------------------------------
// Implementer additions (lead rulings and behaviour beyond the ACs)
// ---------------------------------------------------------------------------

fn fts_results(vault: &Vault, query: &str, k: usize, filters: SearchFilters) -> SearchResults {
    search(
        vault.connection_ref(),
        SearchOptions {
            query,
            k,
            mode: SearchMode::Fts,
            filters,
            embedder: None,
        },
    )
    .unwrap()
}

#[test]
fn topic_already_shown_as_a_direct_hit_above_the_source_is_not_expanded() {
    let (_d, mut vault) = fresh_vault();
    fixture_day(&mut vault);
    create_topic(
        &mut vault,
        "Player Loop",
        "Jump jump jump jump.\n\n![[2026-09-05#^b7k2m9]]\n",
    );

    assert_eq!(
        summary(&fts(&vault, "jump", 10)),
        vec![direct("Player Loop"), direct(DAY)],
        "the topic is shown once, as its direct hit"
    );
}

#[test]
fn topic_expanded_above_its_own_direct_hit_drops_the_lower_direct_hit() {
    let (_d, mut vault) = fresh_vault();
    let day = create_daily(
        &mut vault,
        DAY,
        "Jump jump jump jump.\n\n- tried coyote time\n\nSleep was bad.\n",
    );
    pin_ids(&vault, &day);
    create_topic(
        &mut vault,
        "Player Loop",
        &format!(
            "One jump here. {}\n\n![[2026-09-05#^b7k2m9]]\n",
            filler(120)
        ),
    );
    create_plain(
        &mut vault,
        "Jump Physics",
        &format!("A jump is a parabola. {}", filler(160)),
    );

    assert_eq!(
        summary(&fts(&vault, "jump", 10)),
        vec![direct(DAY), via("Player Loop", DAY), direct("Jump Physics")],
        "the topic appears once, at its higher position"
    );
}

#[test]
fn expanded_topics_must_pass_the_tag_filters() {
    let (_d, mut vault) = fresh_vault();
    let day = fixture_day(&mut vault);
    let tagged = create_topic(&mut vault, "Tagged Loop", "![[2026-09-05#^b7k2m9]]\n");
    create_topic(&mut vault, "Untagged Loop", "![[2026-09-05#^b7k2m9]]\n");
    memex_core::tags::add_tag(&vault, day.id.as_str(), "game").unwrap();
    memex_core::tags::add_tag(&vault, tagged.id.as_str(), "game").unwrap();

    let filters = SearchFilters {
        tags_all: vec!["game".into()],
        note_id: None,
    };
    assert_eq!(
        summary(&fts_results(&vault, "jump", 10, filters).hits),
        vec![direct(DAY), via("Tagged Loop", DAY)]
    );
    assert_eq!(
        summary(&fts(&vault, "jump", 10)),
        vec![
            direct(DAY),
            via("Tagged Loop", DAY),
            via("Untagged Loop", DAY)
        ],
        "without the filter both topics expand"
    );
}

#[test]
fn expanded_topics_must_pass_the_note_id_filter() {
    let (_d, mut vault) = fresh_vault();
    let day = fixture_day(&mut vault);
    create_topic(&mut vault, "Player Loop", "![[2026-09-05#^b7k2m9]]\n");

    let filters = SearchFilters {
        tags_all: Vec::new(),
        note_id: Some(day.id.as_str().to_string()),
    };
    assert_eq!(
        summary(&fts_results(&vault, "jump", 10, filters).hits),
        vec![direct(DAY)]
    );
}

#[test]
fn truncated_reports_expanded_hits_dropped_by_the_k_cap() {
    let (_d, mut vault) = fresh_vault();
    fixture_day(&mut vault);
    for title in ["Topic A", "Topic B", "Topic C"] {
        create_topic(&mut vault, title, "![[2026-09-05#^b7k2m9]]\n");
    }

    let r = fts_results(&vault, "jump", 2, SearchFilters::default());
    assert_eq!(r.hits.len(), 2);
    assert!(r.truncated, "two expanded hits did not fit");

    let r = fts_results(&vault, "jump", 4, SearchFilters::default());
    assert_eq!(r.hits.len(), 4);
    assert!(!r.truncated, "everything fits exactly");

    let r = fts_results(&vault, "jump", 10, SearchFilters::default());
    assert_eq!(r.hits.len(), 4);
    assert!(!r.truncated);
}

#[test]
fn expanded_hit_points_at_the_topic_chunk_holding_the_token() {
    let (_d, mut vault) = fresh_vault();
    fixture_day(&mut vault);
    let topic = create_topic(
        &mut vault,
        "Player Loop",
        &format!(
            "Opening thoughts. {}\n\nMore notes here. ![[2026-09-05#^b7k2m9]]\n",
            filler(300)
        ),
    );
    let chunks = chunk_rows(&vault, &topic.id);
    assert_eq!(chunks.len(), 2, "precondition: the token is in chunk 1");
    assert!(chunks[1].1.contains("![[2026-09-05#^b7k2m9]]"));
    let token_chunk_id: String = vault
        .connection_ref()
        .query_row(
            "SELECT id FROM chunks WHERE note_id = ? AND ord = 1",
            [topic.id.as_str()],
            |r| r.get(0),
        )
        .unwrap();

    let hits = fts(&vault, "jump", 10);
    assert_eq!(summary(&hits), vec![direct(DAY), via("Player Loop", DAY)]);
    let expanded = &hits[1];
    assert_eq!(expanded.note_id, topic.id.as_str());
    assert_eq!(expanded.chunk_id, token_chunk_id);
    assert_eq!(expanded.ord, 1);
    assert!(
        expanded.snippet.contains("![[2026-09-05#^b7k2m9]]"),
        "{:?}",
        expanded.snippet
    );
}

/// Asserts the token of `topic` sits in no stored chunk of it and returns
/// the chunks' ids by ord. Spec #391 req 2: a transclusion-only block is in
/// no chunk, so the D25 expansion cannot find a chunk holding the token.
fn chunk_ids_with_the_token_in_none(vault: &Vault, topic: &Note) -> Vec<String> {
    let body = get_note(vault, &topic.id).unwrap().content_md;
    let at = body.find("![[2026-09-05#^b7k2m9]]").expect("token in body") as i64;
    for (ord, _, start, end) in chunk_rows(vault, &topic.id) {
        let (s, e) = (start.unwrap(), end.unwrap());
        assert!(
            !(s <= at && at < e),
            "precondition: chunk {ord} {s}..{e} must not hold the token at {at}"
        );
    }
    let mut stmt = vault
        .connection_ref()
        .prepare("SELECT id FROM chunks WHERE note_id = ? ORDER BY ord")
        .unwrap();
    let ids = stmt
        .query_map([topic.id.as_str()], |r| r.get::<_, String>(0))
        .unwrap()
        .collect::<Result<_, _>>()
        .unwrap();
    ids
}

/// The one expanded hit of `fts("jump")`, after checking the hit order.
fn the_expanded_jump_hit(vault: &Vault, topic: &Note) -> SearchHit {
    let hits = fts(vault, "jump", 10);
    assert_eq!(
        summary(&hits),
        vec![direct(DAY), via("Player Loop", DAY)],
        "{hits:?}"
    );
    assert_eq!(hits[1].note_id, topic.id.as_str());
    hits[1].clone()
}

fn assert_snippet_is_the_transcluded_text(hit: &SearchHit) {
    assert!(
        hit.snippet.contains("Fixed the jump arc."),
        "the snippet is the transcluded text: {:?}",
        hit.snippet
    );
    assert!(
        !hit.snippet.contains("![["),
        "never the raw token: {:?}",
        hit.snippet
    );
}

#[test]
fn an_excerpt_in_its_own_block_expands_to_the_nearest_chunk_before_it_with_the_transcluded_text() {
    // The layout `add_excerpt` writes: `## <date>`, a blank line, the token
    // as its own block, at the end of a multi-chunk topic.
    let (_d, mut vault) = fresh_vault();
    fixture_day(&mut vault);
    let topic = create_topic(
        &mut vault,
        "Player Loop",
        &format!(
            "Opening thoughts. {}\n\nMiddle section. {}\n",
            filler(300),
            filler(300)
        ),
    );
    add_excerpt(
        &mut vault,
        &topic.id,
        DAY,
        &["b7k2m9".to_string()],
        Caller::Person,
        None,
    )
    .unwrap();
    let ids = chunk_ids_with_the_token_in_none(&vault, &topic);
    assert!(ids.len() >= 2, "precondition: a multi-chunk topic: {ids:?}");

    let hit = the_expanded_jump_hit(&vault, &topic);
    let last = ids.len() - 1;
    assert_eq!(hit.ord, last as i64, "the nearest chunk before the token");
    assert_eq!(hit.chunk_id, ids[last]);
    assert_snippet_is_the_transcluded_text(&hit);
}

#[test]
fn an_excerpt_before_all_chunks_expands_to_the_nearest_chunk_after_it_with_the_transcluded_text() {
    let (_d, mut vault) = fresh_vault();
    fixture_day(&mut vault);
    let topic = create_topic(
        &mut vault,
        "Player Loop",
        &format!(
            "![[2026-09-05#^b7k2m9]]\n\nAfter the excerpt. {}\n\nFurther on. {}\n",
            filler(300),
            filler(300)
        ),
    );
    let ids = chunk_ids_with_the_token_in_none(&vault, &topic);
    assert!(ids.len() >= 2, "precondition: a multi-chunk topic: {ids:?}");

    let hit = the_expanded_jump_hit(&vault, &topic);
    assert_eq!(
        hit.ord, 0,
        "the nearest chunk after the token, not a later one"
    );
    assert_eq!(hit.chunk_id, ids[0]);
    assert_snippet_is_the_transcluded_text(&hit);
}

#[test]
fn an_excerpt_between_two_chunks_expands_to_the_chunk_before_it_even_when_the_one_after_is_nearer()
{
    let (_d, mut vault) = fresh_vault();
    fixture_day(&mut vault);
    let topic = create_topic(
        &mut vault,
        "Player Loop",
        &format!(
            "Before the excerpt. {}\n\n![[2026-09-05#^b7k2m9]]\n\nAfter the excerpt. {}\n",
            filler(300),
            filler(300)
        ),
    );
    let ids = chunk_ids_with_the_token_in_none(&vault, &topic);
    assert_eq!(ids.len(), 2, "precondition: one chunk each side: {ids:?}");

    let hit = the_expanded_jump_hit(&vault, &topic);
    assert_eq!(
        hit.ord, 0,
        "the chunk before the token wins over the nearer one after"
    );
    assert_eq!(hit.chunk_id, ids[0]);
    assert_snippet_is_the_transcluded_text(&hit);
}

#[test]
fn hits_on_a_non_daily_note_titled_like_a_date_never_expand() {
    let (_d, mut vault) = fresh_vault();
    let day = fixture_day(&mut vault);
    create_topic(&mut vault, "Player Loop", "![[2026-09-05#^b7k2m9]]\n");
    assert_eq!(
        summary(&fts(&vault, "jump", 10)),
        vec![direct(DAY), via("Player Loop", DAY)],
        "precondition: the daily note expands"
    );
    // The note loses its daily role but keeps its blocks and chunk ranges.
    vault
        .connection_ref()
        .execute(
            "UPDATE notes SET frontmatter = '{}' WHERE id = ?",
            [day.id.as_str()],
        )
        .unwrap();

    assert_eq!(summary(&fts(&vault, "jump", 10)), vec![direct(DAY)]);
}

#[test]
fn reversed_and_forward_ranges_expand_exactly_the_same_hits() {
    let (_d, mut vault) = fresh_vault();
    long_day(&mut vault);
    create_topic(
        &mut vault,
        "Forward Half",
        "![[2026-09-05#^b7k2m9..^c3d4e5]]\n",
    );
    create_topic(
        &mut vault,
        "Reversed Half",
        "![[2026-09-05#^c3d4e5..^b7k2m9]]\n",
    );

    for query in ["jump", "coyote"] {
        assert_eq!(
            summary(&fts(&vault, query, 10)),
            vec![
                direct(DAY),
                via("Forward Half", DAY),
                via("Reversed Half", DAY)
            ],
            "{query}: both spans cover blocks 0 and 1"
        );
    }
    assert_eq!(
        summary(&fts(&vault, "sleep", 10)),
        vec![direct(DAY)],
        "neither span reaches block 2"
    );
}

#[test]
fn dangling_tokens_cover_nothing_and_a_later_live_token_still_expands() {
    let (_d, mut vault) = fresh_vault();
    long_day(&mut vault);
    create_topic(
        &mut vault,
        "Player Loop",
        "![[2026-09-05#^gone11..^b7k2m9]]\n\n![[2026-09-05#^b7k2m9..^gone22]]\n\n![[2026-09-05#^c3d4e5]]\n",
    );

    assert_eq!(
        summary(&fts(&vault, "jump", 10)),
        vec![direct(DAY)],
        "a range with a missing endpoint does not cover its live endpoint"
    );
    assert_eq!(
        summary(&fts(&vault, "coyote", 10)),
        vec![direct(DAY), via("Player Loop", DAY)],
        "the live third token still expands"
    );
}
