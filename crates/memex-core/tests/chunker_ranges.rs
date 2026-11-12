//! WI #15 (R12): chunk byte ranges (D25).
//!
//! `chunker::chunk` records, for every chunk, a UTF-8 byte range into the
//! chunked input. Sentence sub-chunks of a long block inherit the range of the
//! block they came from. Search expands daily-note hits by overlapping these
//! ranges with block ranges, so the offsets must be bytes, not chars.

use memex_core::chunker::{chunk, split_blocks, Chunk};

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

// ---------------------------------------------------------------------------
// WI #418 (Spec #391 req 2, L6): transclusion-only blocks and the public
// block splitter. A blank-line block made only of C4 transclusion tokens
// (`![[YYYY-MM-DD#^id]]`, `![[YYYY-MM-DD#^a..^b]]`) and whitespace ends the
// current chunk and is in no chunk. `split_blocks` is the chunker's own
// splitter: `(offset, text)` per trimmed block, offsets in its input.
// ---------------------------------------------------------------------------

/// `(content, start_byte, end_byte)` of each chunk, in order.
fn spans(chunks: &[Chunk]) -> Vec<(String, usize, usize)> {
    chunks
        .iter()
        .map(|c| (c.content.clone(), c.start_byte, c.end_byte))
        .collect()
}

/// The span of the first occurrence of `text` in `input`.
fn span_of(input: &str, text: &str) -> (String, usize, usize) {
    let start = input
        .find(text)
        .unwrap_or_else(|| panic!("{text:?} not in {input:?}"));
    (text.to_string(), start, start + text.len())
}

/// Asserts every `(offset, text)` pair points at `text` in `input`.
fn assert_blocks_point_into(input: &str, blocks: &[(usize, &str)]) {
    for (offset, text) in blocks {
        assert_eq!(
            input.get(*offset..*offset + text.len()),
            Some(*text),
            "block {text:?} at offset {offset} must be that slice of its input"
        );
    }
}

#[test]
fn a_transclusion_only_block_is_in_no_chunk_and_the_text_after_it_starts_a_new_chunk() {
    let input = "Alpha para one.\n\nAlpha para two.\n\n![[2026-09-05#^b7k2m9]]\n\nOmega para.";
    let chunks = chunk(input);
    assert_eq!(
        spans(&chunks),
        vec![
            span_of(input, "Alpha para one.\n\nAlpha para two."),
            span_of(input, "Omega para."),
        ],
        "the token block ends the first chunk and is in neither"
    );
    let ords: Vec<i64> = chunks.iter().map(|c| c.ord).collect();
    assert_eq!(ords, vec![0, 1], "ords stay consecutive");
    for c in &chunks {
        assert!(!c.content.contains("![["), "chunk {} holds a token", c.ord);
    }
}

#[test]
fn the_token_count_restarts_after_a_transclusion_only_block_ends_a_chunk() {
    // Three blocks of equal size around a token block. If the running count
    // survived the flush, the third block would look like an overflow and
    // split off a third chunk; with the count restarted, blocks two and
    // three pack together and their token_count is the sum of theirs.
    let (a, b, c) = (filler(100), filler(100), filler(100));
    let input = format!("{a}\n\n![[2026-09-05#^b7k2m9]]\n\n{b}\n\n{c}\n");
    let chunks = chunk(&input);
    assert_eq!(
        spans(&chunks),
        vec![
            span_of(&input, &a),
            span_of(&input, &format!("{}\n\n{c}", &b)),
        ]
    );
    assert!(chunks[0].token_count > 0);
    assert_eq!(
        chunks[1].token_count,
        2 * chunks[0].token_count,
        "the second chunk counts only its own two blocks"
    );
}

#[test]
fn a_block_of_several_tokens_and_whitespace_is_transclusion_only() {
    let input = "Before 🎉.\n\n  ![[2026-09-05#^b7k2m9]]  ![[2026-09-05#^c3d4e5..^f6g7h8]]\n\t![[2026-09-06#^zz9]]![[2026-09-06#^a1]] \n\nAfter.";
    assert_eq!(
        spans(&chunk(input)),
        vec![span_of(input, "Before 🎉."), span_of(input, "After.")],
        "tokens, ranges, tabs, spaces and newlines alone make a transclusion-only block"
    );
}

#[test]
fn transclusion_only_blocks_first_and_last_leave_only_the_middle_chunk() {
    let input = "![[2026-09-05#^b7k2m9]]\n\nZoë 😀 middle text.\n\n![[2026-09-05#^c3d4e5]]\n";
    assert_eq!(
        spans(&chunk(input)),
        vec![span_of(input, "Zoë 😀 middle text.")]
    );
}

#[test]
fn a_note_made_only_of_transclusion_blocks_has_no_chunks() {
    let input = "![[2026-09-05#^b7k2m9]]\n\n  ![[2026-09-06#^c3d4e5..^f6g7h8]]  \n";
    let chunks = chunk(input);
    assert!(
        chunks.is_empty(),
        "no chunk for a body of transclusion-only blocks: {:?}",
        spans(&chunks)
    );
}

#[test]
fn a_block_mixing_a_token_with_text_stays_in_its_chunk() {
    // Guards the other arm: only a block of tokens and whitespace is dropped.
    let input = "Loop notes. ![[2026-09-05#^b7k2m9]]\n\n![[2026-09-05#^c3d4e5]] trailing words\n\n[[Plain Link]]\n\n![alt](image.png)\n\n![[2026-09-05#^bad-id!]]";
    let chunks = chunk(input);
    assert_eq!(
        spans(&chunks),
        vec![(input.to_string(), 0, input.len())],
        "every block has more than tokens and whitespace, so all pack into one chunk"
    );
}

#[test]
fn split_blocks_returns_each_blank_line_block_with_its_byte_offset_in_its_input() {
    let input = "  Café ☕ alpha.\n\nBeta line one\nline two  \n\n\n\n\tZoë 😀 gamma";
    let blocks = split_blocks(input);
    assert_eq!(
        blocks,
        vec![
            (2, "Café ☕ alpha."),
            (input.find("Beta").unwrap(), "Beta line one\nline two"),
            (input.find("Zoë").unwrap(), "Zoë 😀 gamma"),
        ],
        "trimmed blocks at UTF-8 byte offsets"
    );
    assert_blocks_point_into(input, &blocks);
}

#[test]
fn split_blocks_leaves_transclusion_only_blocks_out() {
    let input = "Intro.\n\n![[2026-09-05#^b7k2m9]]\n\n  ![[2026-09-05#^c3d4e5..^f6g7h8]] \n ![[2026-09-06#^a1]]\t\n\nSee ![[2026-09-05#^b7k2m9]] inline.\n\nOutro.";
    let blocks = split_blocks(input);
    assert_eq!(
        blocks,
        vec![
            (0, "Intro."),
            (
                input.find("See ").unwrap(),
                "See ![[2026-09-05#^b7k2m9]] inline."
            ),
            (input.find("Outro.").unwrap(), "Outro."),
        ]
    );
    assert_blocks_point_into(input, &blocks);
}

#[test]
fn split_blocks_of_blank_input_is_empty() {
    assert!(split_blocks("").is_empty());
    assert!(split_blocks("  \n\n \t \n\n").is_empty());
}

#[test]
fn split_blocks_of_a_chunk_points_back_into_the_chunked_input() {
    // V2 (#421) splits a stored chunk's text with this splitter and adds the
    // chunk's start_byte, so a block's offset in the body is
    // chunk.start_byte + its offset in the chunk.
    let input =
        "\n\n  Alpha block.\n\nBeta block 🎉.\n\n\n![[2026-09-05#^b7k2m9]]\n\nGamma ☕.\n\nDelta.";
    let whole = split_blocks(input);
    assert_eq!(
        whole.iter().map(|b| b.1).collect::<Vec<_>>(),
        vec!["Alpha block.", "Beta block 🎉.", "Gamma ☕.", "Delta."],
        "precondition: four prose blocks"
    );
    let chunks = chunk(input);
    assert_eq!(chunks.len(), 2, "the token block splits the note in two");
    let mut rebuilt: Vec<(usize, &str)> = Vec::new();
    for c in &chunks {
        assert_eq!(
            &input[c.start_byte..c.end_byte],
            c.content,
            "chunk {} is its slice",
            c.ord
        );
        for (offset, text) in split_blocks(&c.content) {
            let abs = c.start_byte + offset;
            assert_eq!(input.get(abs..abs + text.len()), Some(text));
            rebuilt.push((abs, &input[abs..abs + text.len()]));
        }
    }
    assert_eq!(
        rebuilt, whole,
        "chunk blocks are exactly the input's blocks"
    );
}

#[test]
fn a_block_with_text_between_two_tokens_or_before_the_first_is_not_transclusion_only() {
    // Text between tokens, before the first token and after the last all keep
    // a block in its chunk.
    for block in [
        "![[2026-09-05#^b7k2m9]] and ![[2026-09-05#^c3d4e5]]",
        "see ![[2026-09-05#^b7k2m9]]",
        "![[2026-09-05#^b7k2m9]] see",
    ] {
        let input = format!("Before.\n\n{block}\n\nAfter.");
        let chunks = chunk(&input);
        assert_eq!(
            spans(&chunks),
            vec![(input.clone(), 0, input.len())],
            "{block:?} stays in the chunk"
        );
        assert_eq!(split_blocks(&input).len(), 3, "{block:?} stays a block");
    }
}
