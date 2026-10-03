//! WI #15 (R12): chunk byte ranges (D25).
//!
//! `chunker::chunk` records, for every chunk, a UTF-8 byte range into the
//! chunked input. Sentence sub-chunks of a long block inherit the range of the
//! block they came from. Search expands daily-note hits by overlapping these
//! ranges with block ranges, so the offsets must be bytes, not chars.

use memex_core::chunker::{chunk, Chunk};

/// `n` filler words that no test queries for.
fn filler(n: usize) -> String {
    const WORDS: [&str; 5] = ["lorem", "ipsum", "dolor", "sit", "amet"];
    (0..n)
        .map(|i| WORDS[i % WORDS.len()])
        .collect::<Vec<_>>()
        .join(" ")
}

/// One paragraph far above the chunker's per-block limit, so it is split
/// into sentence sub-chunks. Sentences are separated by single spaces.
fn long_block(tag: &str) -> String {
    (0..200)
        .map(|i| format!("Sentence {tag} number {i} has some words in it."))
        .collect::<Vec<_>>()
        .join(" ")
}

/// The slice of `input` a chunk's range points at. Fails (instead of
/// panicking) when the range is out of bounds or splits a character.
fn slice<'a>(input: &'a str, c: &Chunk) -> &'a str {
    assert!(
        c.start_byte < c.end_byte,
        "chunk {} has an empty or inverted range {}..{}",
        c.ord,
        c.start_byte,
        c.end_byte
    );
    input.get(c.start_byte..c.end_byte).unwrap_or_else(|| {
        panic!(
            "chunk {} range {}..{} is out of bounds or not on char boundaries (input is {} bytes)",
            c.ord,
            c.start_byte,
            c.end_byte,
            input.len()
        )
    })
}

fn assert_every_slice_contains_its_content(input: &str, chunks: &[Chunk]) {
    assert!(!chunks.is_empty(), "precondition: input yields chunks");
    for c in chunks {
        let s = slice(input, c);
        assert!(
            s.contains(&c.content),
            "chunk {} range {}..{} slices to {:?}, which does not contain its content {:?}",
            c.ord,
            c.start_byte,
            c.end_byte,
            s,
            c.content
        );
    }
}

/// A note with small blocks packed together, two big blocks and a tail, so
/// there are single-block and multi-block chunks.
fn mixed_note() -> String {
    let big1 = format!("First big paragraph {}", filler(280));
    let big2 = format!("Second big paragraph {}", filler(280));
    format!(
        "# Heading\n\nShort paragraph one.\n\nShort paragraph two.\n\n{big1}\n\n{big2}\n\nTail line."
    )
}

#[test]
fn every_chunk_range_slices_to_text_containing_its_content() {
    let input = mixed_note();
    let chunks = chunk(&input);
    assert!(
        chunks.len() >= 3,
        "precondition: expected at least 3 chunks, got {}",
        chunks.len()
    );
    assert_every_slice_contains_its_content(&input, &chunks);
}

#[test]
fn single_chunk_note_range_covers_its_content() {
    let input = "# Hello\n\nThis is a small note with one paragraph.";
    let chunks = chunk(input);
    assert_eq!(chunks.len(), 1);
    let s = slice(input, &chunks[0]);
    assert!(s.contains("# Hello"), "slice {s:?}");
    assert!(s.contains("small note with one paragraph."), "slice {s:?}");
}

#[test]
fn chunk_ranges_skip_leading_blank_lines_and_indentation() {
    let big = format!("Indented big paragraph {}", filler(280));
    let input = format!("\n\n\n   # Heading\n\nShort body.\n\n    {big}\n\n");
    let chunks = chunk(&input);
    assert_eq!(chunks.len(), 2, "precondition: heading chunk + big chunk");
    assert_every_slice_contains_its_content(&input, &chunks);
}

#[test]
fn chunk_ranges_are_increasing_and_non_overlapping() {
    let input = mixed_note();
    let chunks = chunk(&input);
    assert!(
        chunks.len() >= 3,
        "precondition: expected at least 3 chunks"
    );
    for c in &chunks {
        assert!(
            c.start_byte < c.end_byte,
            "chunk {} has an empty range",
            c.ord
        );
        assert!(
            c.end_byte <= input.len(),
            "chunk {} ends past the input",
            c.ord
        );
    }
    for pair in chunks.windows(2) {
        let (a, b) = (&pair[0], &pair[1]);
        assert!(
            a.start_byte < b.start_byte,
            "chunk ranges must increase: {}..{} then {}..{}",
            a.start_byte,
            a.end_byte,
            b.start_byte,
            b.end_byte
        );
        assert!(
            a.end_byte <= b.start_byte,
            "chunk ranges must not overlap: {}..{} then {}..{}",
            a.start_byte,
            a.end_byte,
            b.start_byte,
            b.end_byte
        );
    }
}

#[test]
fn each_chunk_range_excludes_the_neighbouring_chunks_content() {
    let input = mixed_note();
    let chunks = chunk(&input);
    assert!(
        chunks.len() >= 3,
        "precondition: expected at least 3 chunks"
    );
    for (i, c) in chunks.iter().enumerate() {
        let s = slice(&input, c);
        for (j, other) in chunks.iter().enumerate() {
            if i != j {
                assert!(
                    !s.contains(&other.content),
                    "chunk {i} range {}..{} also contains chunk {j}",
                    c.start_byte,
                    c.end_byte
                );
            }
        }
    }
}

#[test]
fn sentence_sub_chunks_share_the_byte_range_of_their_block() {
    let long = long_block("alpha");
    let input = format!("Intro paragraph here.\n\n{long}\n\nOutro paragraph here.");
    let block_start = input.find(&long).unwrap();
    let block_end = block_start + long.len();

    let chunks = chunk(&input);
    assert!(
        chunks.len() >= 4,
        "precondition: intro + at least 2 sub-chunks + outro, got {}",
        chunks.len()
    );
    let (intro, rest) = chunks.split_first().unwrap();
    let (outro, subs) = rest.split_last().unwrap();
    assert_eq!(intro.content, "Intro paragraph here.");
    assert_eq!(outro.content, "Outro paragraph here.");
    assert!(subs.len() >= 2, "precondition: the long block is split");

    for c in subs {
        assert_eq!(
            (c.start_byte, c.end_byte),
            (block_start, block_end),
            "sub-chunk {} must carry its block's range",
            c.ord
        );
        assert!(slice(&input, c).contains(&c.content));
    }
    assert!(
        intro.end_byte <= block_start,
        "intro overlaps the long block"
    );
    assert!(
        outro.start_byte >= block_end,
        "outro overlaps the long block"
    );
    assert!(slice(&input, intro).contains(&intro.content));
    assert!(slice(&input, outro).contains(&outro.content));
}

#[test]
fn sub_chunks_of_a_trimmed_long_block_use_the_trimmed_block_range() {
    let long = long_block("beta");
    let input = format!("\n\n   {long}   \n\n");
    let block_start = input.find(&long).unwrap();
    let block_end = block_start + long.len();

    let chunks = chunk(&input);
    assert!(chunks.len() >= 2, "precondition: the long block is split");
    for c in &chunks {
        assert_eq!(
            (c.start_byte, c.end_byte),
            (block_start, block_end),
            "sub-chunk {} must carry the trimmed block range",
            c.ord
        );
    }
}

#[test]
fn second_long_block_sub_chunks_get_their_own_block_range() {
    let a = long_block("gamma");
    let b = long_block("delta");
    let input = format!("{a}\n\n{b}");
    let a_start = input.find(&a).unwrap();
    let b_start = input.find(&b).unwrap();

    let chunks = chunk(&input);
    let (from_a, from_b): (Vec<&Chunk>, Vec<&Chunk>) =
        chunks.iter().partition(|c| c.content.contains("gamma"));
    assert!(
        from_a.len() >= 2 && from_b.len() >= 2,
        "precondition: both blocks split"
    );
    for c in from_a {
        assert_eq!((c.start_byte, c.end_byte), (a_start, a_start + a.len()));
    }
    for c in from_b {
        assert_eq!((c.start_byte, c.end_byte), (b_start, b_start + b.len()));
    }
}

#[test]
fn ranges_are_utf8_byte_offsets_after_multibyte_text() {
    let p1 = format!("Café ☕ naïve résumé 🎉 {}", filler(250));
    let p2 = format!("Zoë 😀 second paragraph {}", filler(250));
    let p3 = "Ends with an emoji 🎉";
    let input = format!("{p1}\n\n{p2}\n\n{p3}");
    assert!(
        input.len() > input.chars().count(),
        "precondition: multibyte input"
    );

    let chunks = chunk(&input);
    assert!(
        chunks.len() >= 2,
        "precondition: at least 2 chunks, got {}",
        chunks.len()
    );
    assert_every_slice_contains_its_content(&input, &chunks);

    let second = chunks
        .iter()
        .find(|c| c.content.contains("Zoë"))
        .expect("a chunk holds the second paragraph");
    let p2_start = input.find(&p2).unwrap();
    assert!(
        second.start_byte <= p2_start && p2_start + p2.len() <= second.end_byte,
        "chunk range {}..{} must cover the second paragraph at bytes {}..{}",
        second.start_byte,
        second.end_byte,
        p2_start,
        p2_start + p2.len()
    );
    let last = chunks.last().unwrap();
    assert!(
        slice(&input, last).ends_with("🎉"),
        "the last chunk range must end past the trailing emoji"
    );
}

#[test]
fn sub_chunk_ranges_after_emoji_are_exact_byte_offsets() {
    let long = format!("Café 🎉 start. {}", long_block("épsilon"));
    let input = format!("🎉🎉 naïve intro, café.\n\n{long}");
    let block_start = input.find(&long).unwrap();
    let block_end = block_start + long.len();

    let chunks = chunk(&input);
    let subs: Vec<&Chunk> = chunks
        .iter()
        .filter(|c| c.content.contains("épsilon"))
        .collect();
    assert!(subs.len() >= 2, "precondition: the long block is split");
    for c in subs {
        assert_eq!(
            (c.start_byte, c.end_byte),
            (block_start, block_end),
            "sub-chunk {} range must be in UTF-8 bytes",
            c.ord
        );
    }
    let intro = &chunks[0];
    assert!(slice(&input, intro).contains("🎉🎉 naïve intro, café."));
}

#[test]
fn multi_block_chunk_content_is_the_exact_input_slice() {
    let input = "First block.\n\n\n\nSecond block.\n\n\nThird block.\n\n \n\nFourth.";
    let chunks = chunk(input);
    assert_eq!(chunks.len(), 1, "precondition: one packed chunk");
    let c = &chunks[0];
    assert_eq!((c.start_byte, c.end_byte), (0, input.len()));
    assert_eq!(
        c.content, input,
        "extra blank lines between blocks are kept"
    );
}

#[test]
fn chunk_range_starts_at_the_first_block_and_ends_at_the_last_block() {
    let input = "\n\n  Alpha block.\n\nBeta block.  \n\n";
    let chunks = chunk(input);
    assert_eq!(chunks.len(), 1);
    let start = input.find("Alpha").unwrap();
    let end = input.find("block.  ").unwrap() + "block.".len();
    assert_eq!((chunks[0].start_byte, chunks[0].end_byte), (start, end));
    assert_eq!(chunks[0].content, "Alpha block.\n\nBeta block.");
}
