//! WI #418 (Spec #391 requirements 1 and 2, ruling D3, L6): chunks hold only
//! the person's own writing.
//!
//! - `reindex_note` chunks the note's person section: `daily::split_body`'s
//!   region (byte 0 up to the first marker line) for a daily note, and
//!   `tags::person_section` (no frontmatter, up to the first marker line
//!   outside fences) for any other note, chosen from the note's own
//!   frontmatter (`role: daily`).
//! - Frontmatter, the Note footer marker, footer chips (`[[X~about]]`) and
//!   footer tag lines are in no chunk, so their words no longer find the
//!   note through `chunk_fts`.
//! - A blank-line block of only transclusion tokens and whitespace is in no
//!   chunk and ends the chunk before it.
//! - `start_byte..end_byte` stays a range into the full stored body:
//!   `content_md[start_byte..end_byte]` is the chunk's text.
//!
//! Real SQLite, real schema, temp vaults only, no embedding model.

use memex_core::daily::TOPICS_MARKER;
use memex_core::footer::{self, ChipOrigin};
use memex_core::indexer;
use memex_core::notes::{create_note_as, get_note, CreateNote, Note, NoteId};
use memex_core::search::{search, SearchFilters, SearchHit, SearchMode, SearchOptions};
use memex_core::{Caller, Vault};
use serde_json::{json, Value};
use tempfile::TempDir;

// ---- fixtures ---------------------------------------------------------------------------------

const DAY: &str = "2026-09-05";

/// A topic title whose words appear nowhere but in footer chips.
const CHIP_TOPIC: &str = "Zanzibar Plans";

/// `n` filler words that no test queries for.
fn filler(n: usize) -> String {
    const WORDS: [&str; 5] = ["lorem", "ipsum", "dolor", "sit", "amet"];
    (0..n)
        .map(|i| WORDS[i % WORDS.len()])
        .collect::<Vec<_>>()
        .join(" ")
}

/// One paragraph far above the chunker's per-block limit, so it is split
/// into sentence sub-chunks.
fn long_block(tag: &str) -> String {
    (0..200)
        .map(|i| format!("Sentence {tag} number {i} has some words in it."))
        .collect::<Vec<_>>()
        .join(" ")
}

fn fresh_vault() -> (TempDir, Vault) {
    let dir = tempfile::tempdir().unwrap();
    let vault = Vault::create(dir.path()).unwrap();
    (dir, vault)
}

/// Reindexes `id` from `body` without an embedder.
fn reindex(vault: &mut Vault, id: &NoteId, body: &str) {
    indexer::reindex_note(vault.connection_mut(), id.as_str(), body, None)
        .unwrap_or_else(|e| panic!("reindex {id}: {e}"));
}

/// A person-created note, reindexed from its stored body.
fn create(vault: &mut Vault, title: &str, body: &str, fm: Option<Value>) -> Note {
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
    reindex(vault, &note.id, &note.content_md);
    note
}

fn create_plain(vault: &mut Vault, title: &str, body: &str) -> Note {
    create(vault, title, body, None)
}

fn create_topic(vault: &mut Vault, title: &str, body: &str) -> Note {
    create(vault, title, body, Some(json!({ "role": "topic" })))
}

fn create_daily(vault: &mut Vault, date: &str, body: &str) -> Note {
    create(vault, date, body, Some(json!({ "role": "daily" })))
}

/// Adds a person footer chip for `topic` to `host` (which re-renders the
/// footer and reindexes `host` without an embedder) and returns the stored
/// body of `host`.
fn add_chip(vault: &mut Vault, host: &NoteId, topic: &NoteId) -> String {
    footer::set_chip(vault, host, topic, ChipOrigin::Person, None)
        .unwrap_or_else(|e| panic!("set_chip {host} {topic}: {e}"));
    stored_body(vault, host)
}

fn stored_body(vault: &Vault, id: &NoteId) -> String {
    get_note(vault, id).unwrap().content_md
}

/// `(content, start_byte, end_byte)` of a note's stored chunks, by ord.
fn chunks_of(vault: &Vault, id: &NoteId) -> Vec<(String, usize, usize)> {
    let conn = vault.connection_ref();
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

/// The span of the first occurrence of `text` in `body`.
fn span_of(body: &str, text: &str) -> (String, usize, usize) {
    let start = body
        .find(text)
        .unwrap_or_else(|| panic!("{text:?} not in {body:?}"));
    (text.to_string(), start, start + text.len())
}

/// Asserts no stored chunk of `id` contains any of `needles`.
fn assert_no_chunk_contains(vault: &Vault, id: &NoteId, needles: &[&str]) {
    let chunks = chunks_of(vault, id);
    for (content, start, end) in &chunks {
        for needle in needles {
            assert!(
                !content.contains(needle),
                "chunk {start}..{end} {content:?} must not contain {needle:?}"
            );
        }
    }
}

/// Asserts every stored chunk of `id` is exactly its range of `body`.
fn assert_chunks_are_body_slices(vault: &Vault, id: &NoteId, body: &str) {
    let chunks = chunks_of(vault, id);
    assert!(!chunks.is_empty(), "precondition: the note has chunks");
    for (content, start, end) in &chunks {
        assert_eq!(
            body.get(*start..*end),
            Some(content.as_str()),
            "chunk {start}..{end} must be that slice of the full body"
        );
    }
}

fn fts(vault: &Vault, query: &str) -> Vec<SearchHit> {
    search(
        vault.connection_ref(),
        SearchOptions {
            query,
            k: 20,
            mode: SearchMode::Fts,
            filters: SearchFilters::default(),
            embedder: None,
        },
    )
    .unwrap()
    .hits
}

/// Whether an FTS search for `query` returns a direct (not expanded) hit on
/// the note `id`.
fn fts_finds(vault: &Vault, query: &str, id: &NoteId) -> bool {
    fts(vault, query)
        .iter()
        .any(|h| h.note_id == id.as_str() && h.via.is_none())
}

// ---- AC 1: no frontmatter in any chunk ---------------------------------------------------------

const FM_BODY: &str = "---\nsummary: Quokkafrontmatter notes\naliases: [Wombatalias]\ntags: [fmtagword]\n---\n# Heading\n\nBody text café.\n\nSecond paragraph here.\n";

#[test]
fn no_chunk_of_a_note_with_frontmatter_contains_frontmatter_text() {
    let (_d, mut vault) = fresh_vault();
    let plain = create_plain(&mut vault, "Frontmatter plain", FM_BODY);
    let topic = create_topic(&mut vault, "Frontmatter topic", FM_BODY);
    for note in [&plain, &topic] {
        assert!(
            stored_body(&vault, &note.id).starts_with("---\nsummary:"),
            "precondition: the stored body keeps its frontmatter"
        );
        let chunks = chunks_of(&vault, &note.id);
        assert!(
            chunks.iter().any(|c| c.0.contains("Body text café.")),
            "the person text is chunked: {chunks:?}"
        );
        assert_no_chunk_contains(
            &vault,
            &note.id,
            &[
                "Quokkafrontmatter",
                "Wombatalias",
                "fmtagword",
                "summary:",
                "---",
            ],
        );
        assert!(
            !fts_finds(&vault, "Quokkafrontmatter", &note.id),
            "a frontmatter-only word no longer finds {}",
            note.title
        );
        assert!(
            fts_finds(&vault, "Second", &note.id),
            "a person-section word still finds {}",
            note.title
        );
    }
}

#[test]
fn a_note_made_only_of_frontmatter_has_no_chunks() {
    let (_d, mut vault) = fresh_vault();
    let note = create_plain(
        &mut vault,
        "Only frontmatter",
        "---\nsummary: Quokkaonly words\n---\n",
    );
    assert_eq!(chunks_of(&vault, &note.id), Vec::new());
    assert!(!fts_finds(&vault, "Quokkaonly", &note.id));
}

#[test]
fn no_chunk_of_a_daily_note_with_frontmatter_contains_frontmatter_text() {
    // A daily note's section runs from byte 0, but a leading frontmatter
    // block is still no part of it: ranges stay offsets into the full body.
    let (_d, mut vault) = fresh_vault();
    let topic = create_topic(&mut vault, CHIP_TOPIC, "All about the trip.\n");
    let body = "---\nsummary: Quokkadaily words\ntags: [dailyfmtag]\n---\nFixed the jump arc.\n\nSleep was bad.\n";
    let day = create_daily(&mut vault, DAY, body);
    let stored = add_chip(&mut vault, &day.id, &topic.id);
    assert!(
        stored.starts_with("---\nsummary: Quokkadaily"),
        "precondition: the stored daily body keeps its frontmatter: {stored:?}"
    );
    assert!(
        stored.contains(TOPICS_MARKER),
        "precondition: and has a footer: {stored:?}"
    );

    assert_eq!(
        chunks_of(&vault, &day.id),
        vec![span_of(&stored, "Fixed the jump arc.\n\nSleep was bad.")],
        "the one chunk is the person text, as a range of the full body"
    );
    assert_chunks_are_body_slices(&vault, &day.id, &stored);
    assert_no_chunk_contains(
        &vault,
        &day.id,
        &["Quokkadaily", "dailyfmtag", "summary:", "---"],
    );
    assert!(
        !fts_finds(&vault, "Quokkadaily", &day.id),
        "a frontmatter-only word does not find the day"
    );
    assert!(
        fts_finds(&vault, "jump", &day.id),
        "a person-section word still does"
    );
}

#[test]
fn a_daily_note_made_only_of_frontmatter_has_no_chunks() {
    let (_d, mut vault) = fresh_vault();
    let day = create_daily(&mut vault, DAY, "---\nsummary: Quokkadayonly words\n---\n");
    assert_eq!(chunks_of(&vault, &day.id), Vec::new());
    assert!(!fts_finds(&vault, "Quokkadayonly", &day.id));
}

// ---- AC 2: no footer marker, chip or footer tag in any chunk -----------------------------------

#[test]
fn no_chunk_of_a_daily_note_contains_the_footer_marker_or_a_chip() {
    let (_d, mut vault) = fresh_vault();
    let topic = create_topic(&mut vault, CHIP_TOPIC, "All about the trip.\n");
    let day = create_daily(&mut vault, DAY, "Fixed the jump arc.\n\nSleep was bad.\n");
    let body = add_chip(&mut vault, &day.id, &topic.id);
    assert!(
        body.contains(TOPICS_MARKER) && body.contains("[[Zanzibar Plans~about]]"),
        "precondition: the stored daily body has a footer with the chip: {body:?}"
    );

    let chunks = chunks_of(&vault, &day.id);
    assert!(
        chunks.iter().any(|c| c.0.contains("Sleep was bad.")),
        "the person text is chunked: {chunks:?}"
    );
    assert_no_chunk_contains(
        &vault,
        &day.id,
        &[TOPICS_MARKER, "~about]]", "Zanzibar", "memex:topics"],
    );
    assert!(
        !fts_finds(&vault, "Zanzibar", &day.id),
        "a chip title no longer finds the daily note"
    );
    assert!(fts_finds(&vault, "jump", &day.id));
}

#[test]
fn no_chunk_of_a_topic_note_contains_the_footer_marker_or_a_chip() {
    let (_d, mut vault) = fresh_vault();
    let chip = create_topic(&mut vault, CHIP_TOPIC, "All about the trip.\n");
    let host = create_topic(
        &mut vault,
        "Player Loop",
        "Loop notes on momentum.\n\nCoyote time helps.\n",
    );
    let body = add_chip(&mut vault, &host.id, &chip.id);
    assert!(
        body.contains(TOPICS_MARKER) && body.contains("[[Zanzibar Plans~about]]"),
        "precondition: the stored topic body has a Note footer with the chip: {body:?}"
    );

    let chunks = chunks_of(&vault, &host.id);
    assert!(
        chunks.iter().any(|c| c.0.contains("Coyote time helps.")),
        "the person text is chunked: {chunks:?}"
    );
    assert_no_chunk_contains(
        &vault,
        &host.id,
        &[TOPICS_MARKER, "~about]]", "Zanzibar", "memex:topics"],
    );
    assert!(!fts_finds(&vault, "Zanzibar", &host.id));
    assert!(fts_finds(&vault, "momentum", &host.id));
}

#[test]
fn footer_tag_lines_below_the_marker_are_in_no_chunk() {
    let (_d, mut vault) = fresh_vault();
    let note = create_topic(&mut vault, "Tagged topic", "Prose here.\n");
    let body =
        format!("Prose here.\n\n{TOPICS_MARKER}\n[[Zanzibar Plans~about]]\n#footertagword\n");
    reindex(&mut vault, &note.id, &body);
    assert_eq!(
        chunks_of(&vault, &note.id),
        vec![span_of(&body, "Prose here.")]
    );
    assert!(!fts_finds(&vault, "footertagword", &note.id));
}

#[test]
fn daily_stray_text_below_the_marker_is_not_chunked() {
    // LEAD RULING (offsets): a daily note's chunks come from the contiguous
    // region from byte 0 to the first marker line; stray text below the
    // marker (which `split_body` relocates into its owned person string) is
    // not chunked.
    let (_d, mut vault) = fresh_vault();
    let day = create_daily(&mut vault, DAY, "Person words.\n");
    let body =
        format!("Person words.\n{TOPICS_MARKER}\n[[Zanzibar Plans~about]]\nStray quokka line.\n");
    reindex(&mut vault, &day.id, &body);
    assert_eq!(
        chunks_of(&vault, &day.id),
        vec![span_of(&body, "Person words.")]
    );
    assert!(!fts_finds(&vault, "quokka", &day.id));
}

#[test]
fn a_daily_note_is_chunked_only_up_to_its_first_marker_line_even_inside_a_fence() {
    // `daily::split_body` splits at the first marker line anywhere, fenced
    // or not, so the daily note's blocks and chunks share that region.
    let (_d, mut vault) = fresh_vault();
    let day = create_daily(&mut vault, DAY, "Intro words.\n");
    let body = format!(
        "Intro words.\n\n```\n{TOPICS_MARKER}\n```\n\nAfter fence words.\n{TOPICS_MARKER}\n[[Zanzibar Plans~about]]\n"
    );
    reindex(&mut vault, &day.id, &body);
    assert_eq!(
        chunks_of(&vault, &day.id),
        vec![span_of(&body, "Intro words.\n\n```")],
        "a daily note's person section ends at its first marker line"
    );
}

#[test]
fn a_topic_note_keeps_text_after_a_fenced_marker_and_drops_its_footer() {
    // `tags::person_section` ignores a marker line inside fenced code, so a
    // non-daily note's person section runs to the first marker outside it.
    let (_d, mut vault) = fresh_vault();
    let note = create_topic(&mut vault, "Fenced topic", "Intro words.\n");
    let body = format!(
        "Intro words.\n\n```\n{TOPICS_MARKER}\n```\n\nAfter fence words.\n{TOPICS_MARKER}\n[[Zanzibar Plans~about]]\n"
    );
    reindex(&mut vault, &note.id, &body);
    let person_end = body.find("After fence words.").unwrap() + "After fence words.".len();
    assert_eq!(
        chunks_of(&vault, &note.id),
        vec![(body[..person_end].to_string(), 0, person_end)],
        "the fenced marker is person text; the real footer is not chunked"
    );
}

// ---- AC 3: transclusion-only blocks in a saved note --------------------------------------------

#[test]
fn a_saved_topic_note_has_no_chunk_holding_a_transclusion_only_block() {
    let (_d, mut vault) = fresh_vault();
    let body = "Loop notes on momentum.\n\n![[2026-09-05#^b7k2m9]]\n\nMore thoughts after.\n";
    let topic = create_topic(&mut vault, "Player Loop", body);
    let stored = stored_body(&vault, &topic.id);
    assert_eq!(
        chunks_of(&vault, &topic.id),
        vec![
            span_of(&stored, "Loop notes on momentum."),
            span_of(&stored, "More thoughts after."),
        ],
        "the token block is in no chunk and ends the chunk before it"
    );
    assert!(!fts_finds(&vault, "b7k2m9", &topic.id));
    assert!(!fts_finds(&vault, "2026", &topic.id));
}

// ---- AC 4: chunk ranges index the full body ----------------------------------------------------

#[test]
fn every_stored_chunk_is_its_slice_of_the_full_body_after_frontmatter_and_non_ascii_text() {
    let (_d, mut vault) = fresh_vault();
    let body = "---\nsummary: Café ☕ résumé\n---\nZoë 😀 intro paragraph.\n\nNaïve 🎉 second paragraph.\n\n![[2026-09-05#^b7k2m9]]\n\nTail paragraph ☕.\n";
    let note = create_topic(&mut vault, "Ranges topic", body);
    let stored = stored_body(&vault, &note.id);
    assert_eq!(stored, body, "precondition: stored byte for byte");
    assert_eq!(
        chunks_of(&vault, &note.id),
        vec![
            span_of(
                &stored,
                "Zoë 😀 intro paragraph.\n\nNaïve 🎉 second paragraph."
            ),
            span_of(&stored, "Tail paragraph ☕."),
        ]
    );
    assert_chunks_are_body_slices(&vault, &note.id, &stored);
}

#[test]
fn every_stored_chunk_of_a_daily_note_is_its_slice_of_the_full_body() {
    let (_d, mut vault) = fresh_vault();
    let topic = create_topic(&mut vault, CHIP_TOPIC, "All about the trip.\n");
    let f = filler(260);
    let day = create_daily(
        &mut vault,
        DAY,
        &format!("Café ☕ first block. {f}\n\nNaïve 🎉 second block. {f}\n\nZoë 😀 third.\n"),
    );
    let stored = add_chip(&mut vault, &day.id, &topic.id);
    let marker_at = stored.find(TOPICS_MARKER).expect("precondition: a footer");

    let chunks = chunks_of(&vault, &day.id);
    assert!(
        chunks.len() >= 2,
        "precondition: several chunks: {chunks:?}"
    );
    assert_chunks_are_body_slices(&vault, &day.id, &stored);
    for (content, start, end) in &chunks {
        assert!(
            *end <= marker_at,
            "chunk {start}..{end} {content:?} runs into the footer at {marker_at}"
        );
    }
    assert!(chunks.last().unwrap().0.ends_with("Zoë 😀 third."));
}

#[test]
fn sentence_sub_chunks_after_frontmatter_carry_their_block_range_in_the_full_body() {
    let (_d, mut vault) = fresh_vault();
    let long = long_block("épsilon");
    let body = format!("---\nsummary: Quokkalong\n---\n{long}\n");
    let note = create_plain(&mut vault, "Long after frontmatter", &body);
    let stored = stored_body(&vault, &note.id);
    let block = span_of(&stored, &long);

    let chunks = chunks_of(&vault, &note.id);
    assert!(chunks.len() >= 2, "precondition: the long block is split");
    for (content, start, end) in &chunks {
        assert_eq!(
            (*start, *end),
            (block.1, block.2),
            "sub-chunk {content:?} carries its block's range in the full body"
        );
        assert!(stored[*start..*end].contains(content.as_str()));
        assert!(!content.contains("Quokkalong"));
    }
}

#[test]
fn a_note_without_frontmatter_or_footer_is_chunked_whole() {
    // Guards the other arm: a body with no frontmatter and no marker is all
    // person section, so its chunks are the chunker's chunks of the body.
    let (_d, mut vault) = fresh_vault();
    let body = "# Title\n\nFirst paragraph.\n\nSecond paragraph 🎉.\n";
    let note = create_plain(&mut vault, "Whole note", body);
    let stored = stored_body(&vault, &note.id);
    assert_eq!(
        chunks_of(&vault, &note.id),
        vec![span_of(
            &stored,
            "# Title\n\nFirst paragraph.\n\nSecond paragraph 🎉."
        )]
    );
}

#[test]
fn a_daily_note_without_a_footer_marker_is_chunked_whole_with_full_body_ranges() {
    let (_d, mut vault) = fresh_vault();
    let day = create_daily(&mut vault, DAY, "Placeholder.\n");
    // Creating a daily note renders a footer; store a body without one.
    let stored = "Café ☕ one.\n\nZoë 😀 two.\n".to_string();
    vault
        .connection_ref()
        .execute(
            "UPDATE notes SET content_md = ? WHERE id = ?",
            rusqlite::params![stored, day.id.as_str()],
        )
        .unwrap();
    reindex(&mut vault, &day.id, &stored);
    assert!(!stored.contains(TOPICS_MARKER), "precondition: no footer");
    assert_eq!(
        chunks_of(&vault, &day.id),
        vec![span_of(&stored, "Café ☕ one.\n\nZoë 😀 two.")]
    );
    assert_chunks_are_body_slices(&vault, &day.id, &stored);
}
