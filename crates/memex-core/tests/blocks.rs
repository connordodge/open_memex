//! WI #6 (architect D12, D2): the pure block engine in `memex_core::blocks`.
//! `split`, `content_hash`, `short_id`, `match_blocks` and `diff`, with no
//! database and no clock. Randomness is injected, so every test is deterministic.

use std::collections::HashSet;

use memex_core::blocks::{
    content_hash, diff, match_blocks, short_id, split, Block, BlockKind, MatchOutcome,
    SnapshotBlock, SplitBlock,
};

const ALPHABET: &str = "0123456789abcdefghjkmnpqrstvwxyz";

// ---- helpers -----------------------------------------------------------------------------------

fn sb(kind: BlockKind, start_byte: usize, end_byte: usize, text: &str) -> SplitBlock {
    SplitBlock {
        kind,
        start_byte,
        end_byte,
        text: text.to_string(),
    }
}

/// Splits `input`, checks every block's text is the exact source slice, and
/// compares against `expected`.
fn assert_split(input: &str, expected: &[SplitBlock]) {
    let got = split(input);
    for b in &got {
        assert!(
            input.is_char_boundary(b.start_byte) && input.is_char_boundary(b.end_byte),
            "range [{}, {}) is not on char boundaries of {input:?}",
            b.start_byte,
            b.end_byte
        );
        assert_eq!(
            &input[b.start_byte..b.end_byte],
            b.text,
            "block text must be the exact source slice"
        );
    }
    assert_eq!(got, expected, "split({input:?})");
}

/// SplitMix64: a deterministic, well-mixed randomness source.
fn splitmix(seed: u64) -> impl FnMut() -> u64 {
    let mut state = seed;
    move || {
        state = state.wrapping_add(0x9E37_79B9_7F4A_7C15);
        let mut z = state;
        z = (z ^ (z >> 30)).wrapping_mul(0xBF58_476D_1CE4_E5B9);
        z = (z ^ (z >> 27)).wrapping_mul(0x94D0_49BB_1331_11EB);
        z ^ (z >> 31)
    }
}

/// A rigged source: yields `value` for the first `stuck` draws, then SplitMix64.
/// Replaying it from the start makes the first attempt reproduce the same id.
fn stuck_then_random(value: u64, stuck: usize, seed: u64) -> impl FnMut() -> u64 {
    let mut left = stuck;
    let mut rest = splitmix(seed);
    move || {
        if left > 0 {
            left -= 1;
            value
        } else {
            rest()
        }
    }
}

fn assert_valid_id(id: &str) {
    assert_eq!(id.len(), 6, "short id {id:?} must be 6 chars");
    assert!(
        id.chars().all(|c| ALPHABET.contains(c)),
        "short id {id:?} must only use {ALPHABET}"
    );
}

/// Stored `blocks` rows for `body`: split, then ids assigned in order, with
/// `source` `person` and `created_version` 1.
fn stored(body: &str, ids: &[&str]) -> Vec<Block> {
    let parts = split(body);
    assert_eq!(parts.len(), ids.len(), "fixture {body:?} block count");
    parts
        .into_iter()
        .zip(ids)
        .enumerate()
        .map(|(ord, (p, id))| Block {
            block_id: id.to_string(),
            ord,
            start_byte: p.start_byte,
            end_byte: p.end_byte,
            content_hash: content_hash(&p.text),
            text: p.text,
            source: "person".to_string(),
            created_version: 1,
        })
        .collect()
}

/// Re-splits `new_body` and matches it against `old` as a `person` write at version 2.
fn rematch(old: &[Block], new_body: &str) -> MatchOutcome {
    match_blocks(old, &split(new_body), "person", 2, &mut splitmix(7))
}

fn ids(blocks: &[Block]) -> Vec<&str> {
    blocks.iter().map(|b| b.block_id.as_str()).collect()
}

fn texts(blocks: &[Block]) -> Vec<&str> {
    blocks.iter().map(|b| b.text.as_str()).collect()
}

/// Every output block is consistent: ord = index, the hash is the hash of the
/// text, the text is the source slice, and ids are valid and unique.
fn assert_consistent(outcome: &MatchOutcome, new_body: &str) {
    let mut seen = HashSet::new();
    for (i, b) in outcome.blocks.iter().enumerate() {
        assert_eq!(b.ord, i, "block {:?} ord", b.text);
        assert_eq!(
            b.content_hash,
            content_hash(&b.text),
            "block {:?} hash",
            b.text
        );
        assert_eq!(&new_body[b.start_byte..b.end_byte], b.text);
        assert!(
            b.block_id.chars().all(|c| ALPHABET.contains(c)) && !b.block_id.is_empty(),
            "block id {:?} must match C4's [0-9a-z]{{1,26}} over the Crockford alphabet",
            b.block_id
        );
        assert!(
            seen.insert(b.block_id.clone()),
            "duplicate id {:?}",
            b.block_id
        );
    }
}

fn snap(id: &str, text: &str) -> SnapshotBlock {
    SnapshotBlock {
        block_id: id.to_string(),
        content_hash: content_hash(text),
        text: text.to_string(),
    }
}

fn cur(id: &str, ord: usize, text: &str, source: &str) -> Block {
    Block {
        block_id: id.to_string(),
        ord,
        start_byte: 0,
        end_byte: text.len(),
        text: text.to_string(),
        content_hash: content_hash(text),
        source: source.to_string(),
        created_version: 1,
    }
}

const AC1_BODY: &str =
    "Fixed the jump arc.\n\n- tried coyote time\n- added buffer\n\n## Sleep\nSleep was bad.\n";

// ---- split (AC 1-4) ----------------------------------------------------------------------------

#[test]
fn split_daily_fixture_returns_five_blocks_with_kinds_and_byte_ranges() {
    assert_split(
        AC1_BODY,
        &[
            sb(BlockKind::Paragraph, 0, 19, "Fixed the jump arc."),
            sb(BlockKind::ListItem, 21, 40, "- tried coyote time"),
            sb(BlockKind::ListItem, 41, 55, "- added buffer"),
            sb(BlockKind::Heading, 57, 65, "## Sleep"),
            sb(BlockKind::Paragraph, 66, 80, "Sleep was bad."),
        ],
    );
}

#[test]
fn split_multibyte_text_uses_utf8_byte_ranges_on_char_boundaries() {
    assert_split(
        "café\n\nnaïve",
        &[
            sb(BlockKind::Paragraph, 0, 5, "café"),
            sb(BlockKind::Paragraph, 7, 13, "naïve"),
        ],
    );
}

#[test]
fn split_mixed_multibyte_heading_list_and_paragraph_use_byte_ranges() {
    assert_split(
        "## Café ☕\n- naïve 日本\n\nÜber alles.",
        &[
            sb(BlockKind::Heading, 0, 12, "## Café ☕"),
            sb(BlockKind::ListItem, 13, 28, "- naïve 日本"),
            sb(BlockKind::Paragraph, 30, 42, "Über alles."),
        ],
    );
}

#[test]
fn split_fenced_code_with_blank_line_is_one_block() {
    assert_split(
        "Before.\n\n```\nlet a = 1;\n\nlet b = 2;\n```\n\nAfter.",
        &[
            sb(BlockKind::Paragraph, 0, 7, "Before."),
            sb(BlockKind::Code, 9, 39, "```\nlet a = 1;\n\nlet b = 2;\n```"),
            sb(BlockKind::Paragraph, 41, 47, "After."),
        ],
    );
}

#[test]
fn split_never_splits_inside_a_fence_on_list_or_heading_lines() {
    assert_split(
        "```rust\n- not a list\n# not a heading\n\n```",
        &[sb(
            BlockKind::Code,
            0,
            41,
            "```rust\n- not a list\n# not a heading\n\n```",
        )],
    );
}

#[test]
fn split_unclosed_fence_runs_to_end_of_input() {
    // No closing fence: the code block runs to the end (never split, never panics).
    assert_split(
        "Before.\n\n```\ncode\n\nmore\n",
        &[
            sb(BlockKind::Paragraph, 0, 7, "Before."),
            sb(BlockKind::Code, 9, 23, "```\ncode\n\nmore"),
        ],
    );
}

#[test]
fn split_multi_line_paragraph_is_one_block() {
    assert_split(
        "line one\nline two\n\nnext",
        &[
            sb(BlockKind::Paragraph, 0, 17, "line one\nline two"),
            sb(BlockKind::Paragraph, 19, 23, "next"),
        ],
    );
}

#[test]
fn split_empty_input_returns_no_blocks() {
    assert_eq!(split(""), Vec::<SplitBlock>::new());
}

#[test]
fn split_whitespace_only_input_returns_no_blocks() {
    assert_eq!(split("   \n\n \t\n\n"), Vec::<SplitBlock>::new());
    assert_eq!(split("\n"), Vec::<SplitBlock>::new());
}

#[test]
fn split_ignores_leading_and_trailing_blank_lines() {
    assert_split(
        "\n\n  \nhello\n\n\n",
        &[sb(BlockKind::Paragraph, 5, 10, "hello")],
    );
}

#[test]
fn split_whitespace_only_line_separates_blocks() {
    assert_split(
        "a\n \t\nb",
        &[
            sb(BlockKind::Paragraph, 0, 1, "a"),
            sb(BlockKind::Paragraph, 5, 6, "b"),
        ],
    );
}

#[test]
fn split_heading_levels_one_to_six_need_a_space() {
    assert_split(
        "# a\n###### b\n####### c\n#d",
        &[
            sb(BlockKind::Heading, 0, 3, "# a"),
            sb(BlockKind::Heading, 4, 12, "###### b"),
            sb(BlockKind::Paragraph, 13, 25, "####### c\n#d"),
        ],
    );
}

#[test]
fn split_heading_line_interrupts_a_paragraph() {
    assert_split(
        "before\n# Head\nafter",
        &[
            sb(BlockKind::Paragraph, 0, 6, "before"),
            sb(BlockKind::Heading, 7, 13, "# Head"),
            sb(BlockKind::Paragraph, 14, 19, "after"),
        ],
    );
}

#[test]
fn split_each_list_marker_starts_its_own_block() {
    assert_split(
        "- a\n* b\n+ c\n1. d\n10. e\n  - f",
        &[
            sb(BlockKind::ListItem, 0, 3, "- a"),
            sb(BlockKind::ListItem, 4, 7, "* b"),
            sb(BlockKind::ListItem, 8, 11, "+ c"),
            sb(BlockKind::ListItem, 12, 16, "1. d"),
            sb(BlockKind::ListItem, 17, 22, "10. e"),
            sb(BlockKind::ListItem, 23, 28, "  - f"),
        ],
    );
}

#[test]
fn split_list_item_keeps_deeper_indented_continuation_lines() {
    assert_split(
        "- item\n  more of item\n- next",
        &[
            sb(BlockKind::ListItem, 0, 21, "- item\n  more of item"),
            sb(BlockKind::ListItem, 22, 28, "- next"),
        ],
    );
}

#[test]
fn split_unindented_line_after_list_item_starts_a_paragraph() {
    assert_split(
        "- item\nplain line\nstill plain",
        &[
            sb(BlockKind::ListItem, 0, 6, "- item"),
            sb(BlockKind::Paragraph, 7, 29, "plain line\nstill plain"),
        ],
    );
}

#[test]
fn split_line_at_same_indent_as_list_item_is_not_a_continuation() {
    assert_split(
        "  - a\n  same level",
        &[
            sb(BlockKind::ListItem, 0, 5, "  - a"),
            sb(BlockKind::Paragraph, 6, 18, "  same level"),
        ],
    );
}

#[test]
fn split_list_item_line_interrupts_a_paragraph() {
    assert_split(
        "Intro:\n- a",
        &[
            sb(BlockKind::Paragraph, 0, 6, "Intro:"),
            sb(BlockKind::ListItem, 7, 10, "- a"),
        ],
    );
}

#[test]
fn split_marker_without_space_is_not_a_list_item() {
    assert_split(
        "-dash\n1.5 apples\n*stars*\n. no digits",
        &[sb(
            BlockKind::Paragraph,
            0,
            36,
            "-dash\n1.5 apples\n*stars*\n. no digits",
        )],
    );
}

// ---- content_hash (AC 5) -----------------------------------------------------------------------

#[test]
fn content_hash_matches_fnv1a_64_test_vectors() {
    assert_eq!(content_hash(""), "cbf29ce484222325");
    assert_eq!(content_hash("a"), "af63dc4c8601ec8c");
    assert_eq!(content_hash("foobar"), "85944171f73967e8");
}

#[test]
fn content_hash_is_zero_padded_to_sixteen_hex_chars() {
    // FNV-1a-64("baa") = 0x0039231913392937: the leading zeros must be kept.
    assert_eq!(content_hash("baa"), "0039231913392937");
}

#[test]
fn content_hash_hashes_utf8_bytes() {
    assert_eq!(content_hash("café"), "48e8823acfa40d89");
    assert_eq!(content_hash("Fixed the jump arc."), "c7668eb8188d6414");
}

// ---- short_id (AC 6) ---------------------------------------------------------------------------

#[test]
fn short_id_is_six_lowercase_crockford_chars() {
    let mut rng = splitmix(1);
    for _ in 0..200 {
        assert_valid_id(&short_id(&HashSet::new(), &mut rng));
    }
}

#[test]
fn short_id_never_returns_a_taken_id() {
    let mut rng = splitmix(2);
    let mut taken = HashSet::new();
    for _ in 0..2000 {
        let id = short_id(&taken, &mut rng);
        assert_valid_id(&id);
        assert!(
            taken.insert(id.clone()),
            "short_id returned taken id {id:?}"
        );
    }
}

#[test]
fn short_id_retries_when_the_source_first_yields_a_taken_id() {
    // The same rigged source, replayed from the start, reproduces `first` on
    // its first attempt; with `first` taken the generator must draw again.
    let first = short_id(&HashSet::new(), &mut stuck_then_random(42, 12, 3));
    assert_valid_id(&first);
    let taken: HashSet<String> = [first.clone()].into_iter().collect();
    let second = short_id(&taken, &mut stuck_then_random(42, 12, 3));
    assert_valid_id(&second);
    assert_ne!(second, first, "a taken id must never be returned");
}

#[test]
fn short_id_uses_every_alphabet_char_at_every_position() {
    let mut rng = splitmix(4);
    let ids: Vec<String> = (0..2000)
        .map(|_| short_id(&HashSet::new(), &mut rng))
        .collect();
    for pos in 0..6 {
        let used: HashSet<char> = ids.iter().map(|id| id.chars().nth(pos).unwrap()).collect();
        let missing: String = ALPHABET.chars().filter(|c| !used.contains(c)).collect();
        assert!(
            missing.is_empty(),
            "position {pos} never used {missing:?} over 2000 ids"
        );
    }
}

// ---- match_blocks (AC 7-12) --------------------------------------------------------------------

#[test]
fn first_save_gives_every_block_a_fresh_id() {
    let out = rematch(&[], AC1_BODY);
    assert_consistent(&out, AC1_BODY);
    assert_eq!(out.blocks.len(), 5);
    assert!(out.removed.is_empty());
    for b in &out.blocks {
        assert_valid_id(&b.block_id);
        assert_eq!(b.source, "person");
        assert_eq!(b.created_version, 2);
    }
}

#[test]
fn edited_paragraph_at_same_position_keeps_its_id() {
    let old = stored(
        AC1_BODY,
        &["a00001", "a00002", "a00003", "a00004", "a00005"],
    );
    let new_body = AC1_BODY.replace("Fixed the jump arc.", "Fixed the jump arc today.");
    let out = rematch(&old, &new_body);
    assert_consistent(&out, &new_body);
    assert_eq!(
        ids(&out.blocks),
        ["a00001", "a00002", "a00003", "a00004", "a00005"]
    );
    assert_eq!(out.blocks[0].text, "Fixed the jump arc today.");
    assert!(out.removed.is_empty());
}

#[test]
fn matched_block_carries_new_text_hash_and_byte_ranges() {
    let old = stored(
        AC1_BODY,
        &["a00001", "a00002", "a00003", "a00004", "a00005"],
    );
    let new_body = AC1_BODY.replace("Fixed the jump arc.", "Fixed the jump arc today.");
    let out = rematch(&old, &new_body);
    assert_eq!(
        out.blocks[0],
        Block {
            block_id: "a00001".into(),
            ord: 0,
            start_byte: 0,
            end_byte: 25,
            text: "Fixed the jump arc today.".into(),
            content_hash: content_hash("Fixed the jump arc today."),
            source: "person".into(),
            created_version: 1,
        }
    );
    // The hash-matched heading moved 6 bytes later.
    assert_eq!(out.blocks[3].block_id, "a00004");
    assert_eq!((out.blocks[3].start_byte, out.blocks[3].end_byte), (63, 71));
}

#[test]
fn reordered_blocks_keep_ids_and_take_new_ords() {
    let old = stored(
        "Alpha.\n\nBravo.\n\nCharlie.",
        &["aaaaaa", "bbbbbb", "cccccc"],
    );
    let new_body = "Charlie.\n\nAlpha.\n\nBravo.";
    let out = rematch(&old, new_body);
    assert_consistent(&out, new_body);
    assert_eq!(ids(&out.blocks), ["cccccc", "aaaaaa", "bbbbbb"]);
    assert_eq!(texts(&out.blocks), ["Charlie.", "Alpha.", "Bravo."]);
    assert_eq!(
        out.blocks.iter().map(|b| b.ord).collect::<Vec<_>>(),
        [0, 1, 2]
    );
    assert_eq!(
        out.blocks
            .iter()
            .map(|b| (b.start_byte, b.end_byte))
            .collect::<Vec<_>>(),
        [(0, 8), (10, 16), (18, 24)]
    );
    assert!(out.removed.is_empty());
}

#[test]
fn deleting_middle_block_reports_it_removed_and_keeps_neighbours() {
    let old = stored(
        "Alpha.\n\nBravo.\n\nCharlie.",
        &["aaaaaa", "bbbbbb", "cccccc"],
    );
    let new_body = "Alpha.\n\nCharlie.";
    let out = rematch(&old, new_body);
    assert_consistent(&out, new_body);
    assert_eq!(ids(&out.blocks), ["aaaaaa", "cccccc"]);
    assert_eq!(out.blocks[1].ord, 1);
    assert_eq!(out.removed, vec![old[1].clone()]);
}

#[test]
fn replaced_paragraph_below_threshold_gets_new_id_and_old_is_removed() {
    let old = stored(
        AC1_BODY,
        &["a00001", "a00002", "a00003", "a00004", "a00005"],
    );
    let new_body = AC1_BODY.replace("Sleep was bad.", "Bought groceries.");
    let out = rematch(&old, &new_body);
    assert_consistent(&out, &new_body);
    assert_eq!(
        ids(&out.blocks)[..4],
        ["a00001", "a00002", "a00003", "a00004"]
    );
    let fresh = &out.blocks[4];
    assert_eq!(fresh.text, "Bought groceries.");
    assert_valid_id(&fresh.block_id);
    assert!(
        !["a00001", "a00002", "a00003", "a00004", "a00005"].contains(&fresh.block_id.as_str()),
        "replacement must get a fresh id, got {:?}",
        fresh.block_id
    );
    assert_eq!(out.removed, vec![old[4].clone()]);
}

#[test]
fn identical_paragraphs_get_distinct_ids() {
    // The rigged source repeats the same value, so a generator that does not
    // treat ids it just minted as taken hands out the same id twice.
    let body = "ok\n\nok";
    let out = match_blocks(
        &[],
        &split(body),
        "person",
        1,
        &mut stuck_then_random(9, 12, 5),
    );
    assert_consistent(&out, body);
    assert_eq!(out.blocks.len(), 2);
    assert_ne!(out.blocks[0].block_id, out.blocks[1].block_id);
}

#[test]
fn identical_paragraphs_keep_their_ids_after_insert_between() {
    let old = stored("ok\n\nok", &["frst01", "scnd02"]);
    let new_body = "ok\n\nSomething new in the middle.\n\nok";
    let out = rematch(&old, new_body);
    assert_consistent(&out, new_body);
    assert_eq!(out.blocks[0].block_id, "frst01");
    assert_eq!(out.blocks[2].block_id, "scnd02");
    assert!(!["frst01", "scnd02"].contains(&out.blocks[1].block_id.as_str()));
    assert!(out.removed.is_empty());
}

#[test]
fn deleting_first_of_two_identical_paragraphs_keeps_the_nearest_id() {
    // Old: ok(ord 0), Alpha, Bravo, ok(ord 3). The first `ok` is deleted; the
    // remaining `ok` lands at ord 2, nearest to the old ord 3.
    let old = stored(
        "ok\n\nAlpha.\n\nBravo.\n\nok",
        &["frst01", "aaaaaa", "bbbbbb", "scnd02"],
    );
    let new_body = "Alpha.\n\nBravo.\n\nok";
    let out = rematch(&old, new_body);
    assert_consistent(&out, new_body);
    assert_eq!(ids(&out.blocks), ["aaaaaa", "bbbbbb", "scnd02"]);
    assert_eq!(out.removed, vec![old[0].clone()]);
}

#[test]
fn each_old_block_matches_at_most_once() {
    let old = stored("ok\n\nok", &["frst01", "scnd02"]);
    let new_body = "ok\n\nok\n\nok";
    let out = rematch(&old, new_body);
    assert_consistent(&out, new_body);
    assert_eq!(&ids(&out.blocks)[..2], ["frst01", "scnd02"]);
    assert!(!["frst01", "scnd02"].contains(&out.blocks[2].block_id.as_str()));
    assert_eq!(out.blocks[2].created_version, 2);
}

#[test]
fn exact_hash_match_beats_positional_similarity() {
    // New ord 0 is 0.76 similar to old ord 0 at the same position, but it is an
    // exact copy of old ord 1, and hash matches are taken first.
    let old = stored(
        "Fixed the jump arc.\n\nFixed the jump arc today.",
        &["aaaaaa", "bbbbbb"],
    );
    let new_body = "Fixed the jump arc today.";
    let out = rematch(&old, new_body);
    assert_eq!(ids(&out.blocks), ["bbbbbb"]);
    assert_eq!(out.removed, vec![old[0].clone()]);
}

#[test]
fn hash_matched_old_block_is_not_reused_by_similarity() {
    let old = stored("Fixed the jump arc.", &["aaaaaa"]);
    let new_body = "Fixed the jump arc.\n\nFixed the jump arc today.";
    let out = rematch(&old, new_body);
    assert_consistent(&out, new_body);
    assert_eq!(out.blocks[0].block_id, "aaaaaa");
    assert_ne!(out.blocks[1].block_id, "aaaaaa");
    assert_eq!(out.blocks[1].created_version, 2);
}

#[test]
fn similarity_exactly_at_threshold_keeps_id() {
    let s = strsim::normalized_levenshtein("Slept well", "Slept late");
    assert_eq!(s.to_bits(), 0.6f64.to_bits(), "fixture must sit on 0.6");
    let old = stored("Slept well", &["aaaaaa"]);
    let out = rematch(&old, "Slept late");
    assert_eq!(ids(&out.blocks), ["aaaaaa"]);
    assert!(out.removed.is_empty());
}

#[test]
fn similarity_just_below_threshold_gets_new_id() {
    let s = strsim::normalized_levenshtein("Gym at seven", "Gym at noon!");
    assert!(s < 0.6 && s > 0.58, "fixture similarity {s}");
    let old = stored("Gym at seven", &["aaaaaa"]);
    let out = rematch(&old, "Gym at noon!");
    assert_eq!(out.blocks.len(), 1);
    assert_ne!(out.blocks[0].block_id, "aaaaaa");
    assert_eq!(out.removed, vec![old[0].clone()]);
}

#[test]
fn similarity_tie_prefers_the_same_position() {
    // Both old blocks are 0.6 similar to the new block at ord 0; the one at
    // the same position (ord 0) wins over the adjacent one (ord 1).
    let old = stored("Slept well\n\nSlept well", &["aaaaaa", "bbbbbb"]);
    let out = rematch(&old, "Slept late");
    assert_eq!(ids(&out.blocks), ["aaaaaa"]);
    assert_eq!(out.removed, vec![old[1].clone()]);
}

const POS_OLD: &str = "Zebra crossing.\n\nQuiet morning.\n\nFixed the jump arc.";
const POS_IDS: [&str; 3] = ["zzzzzz", "qqqqqq", "ffffff"];

#[test]
fn similar_block_one_position_later_keeps_id() {
    // Old ord 2 -> new ord 3.
    let old = stored(POS_OLD, &POS_IDS);
    let new_body =
        "Zebra crossing.\n\nQuiet morning.\n\nBrand new thought here.\n\nFixed the jump arc today.";
    let out = rematch(&old, new_body);
    assert_consistent(&out, new_body);
    assert_eq!(out.blocks[3].block_id, "ffffff");
    assert!(out.removed.is_empty());
}

#[test]
fn similar_block_two_positions_later_gets_new_id() {
    // Old ord 2 -> new ord 4: outside the adjacent window.
    let old = stored(POS_OLD, &POS_IDS);
    let new_body = "Zebra crossing.\n\nQuiet morning.\n\nBrand new thought here.\n\nAnother fresh line!\n\nFixed the jump arc today.";
    let out = rematch(&old, new_body);
    assert_consistent(&out, new_body);
    assert_eq!(&ids(&out.blocks)[..2], ["zzzzzz", "qqqqqq"]);
    assert!(!POS_IDS.contains(&out.blocks[4].block_id.as_str()));
    assert_eq!(out.removed, vec![old[2].clone()]);
}

#[test]
fn similar_block_one_position_earlier_keeps_id() {
    // Old ord 2 -> new ord 1.
    let old = stored(POS_OLD, &POS_IDS);
    let new_body = "Quiet morning.\n\nFixed the jump arc today.";
    let out = rematch(&old, new_body);
    assert_consistent(&out, new_body);
    assert_eq!(ids(&out.blocks), ["qqqqqq", "ffffff"]);
    assert_eq!(out.removed, vec![old[0].clone()]);
}

#[test]
fn similar_block_two_positions_earlier_gets_new_id() {
    // Old ord 2 -> new ord 0.
    let old = stored(POS_OLD, &POS_IDS);
    let new_body = "Fixed the jump arc today.";
    let out = rematch(&old, new_body);
    assert_consistent(&out, new_body);
    assert!(!POS_IDS.contains(&out.blocks[0].block_id.as_str()));
    assert_eq!(out.removed, old);
}

#[test]
fn matched_blocks_keep_source_and_created_version() {
    let mut old = stored(
        "Captured by agent.\n\nFixed the jump arc.",
        &["aaaaaa", "bbbbbb"],
    );
    for b in &mut old {
        b.source = "agent".into();
        b.created_version = 3;
    }
    // Block 0 matches by hash, block 1 by similarity; the write is a person write.
    let new_body = "Captured by agent.\n\nFixed the jump arc today.";
    let out = match_blocks(&old, &split(new_body), "person", 7, &mut splitmix(8));
    assert_eq!(ids(&out.blocks), ["aaaaaa", "bbbbbb"]);
    for b in &out.blocks {
        assert_eq!(b.source, "agent", "block {:?}", b.text);
        assert_eq!(b.created_version, 3, "block {:?}", b.text);
    }
}

#[test]
fn new_blocks_take_the_write_source_and_version() {
    let old = stored("Fixed the jump arc.", &["aaaaaa"]);
    let new_body = "Fixed the jump arc.\n\nAdded via quick entry.";
    let out = match_blocks(&old, &split(new_body), "quick-entry", 7, &mut splitmix(8));
    assert_consistent(&out, new_body);
    assert_eq!(out.blocks[0].source, "person");
    assert_eq!(out.blocks[0].created_version, 1);
    assert_eq!(out.blocks[1].source, "quick-entry");
    assert_eq!(out.blocks[1].created_version, 7);
}

#[test]
fn fresh_ids_avoid_every_existing_id_in_the_note() {
    // `taken_first` is the id the seed produces first. It already belongs to a
    // kept block (and to a removed one in the second case), so a fresh block
    // replaying that seed must not reuse it.
    let taken_first = short_id(&HashSet::new(), &mut splitmix(11));

    let mut kept = stored("Kept line.", &["aaaaaa"]);
    kept[0].block_id = taken_first.clone();
    let body = "Kept line.\n\nSomething else entirely.";
    let out = match_blocks(&kept, &split(body), "person", 2, &mut splitmix(11));
    assert_consistent(&out, body);
    assert_eq!(out.blocks[0].block_id, taken_first);
    assert_ne!(out.blocks[1].block_id, taken_first);

    let mut gone = stored("Old line.", &["aaaaaa"]);
    gone[0].block_id = taken_first.clone();
    let out = match_blocks(
        &gone,
        &split("Totally different words"),
        "person",
        2,
        &mut splitmix(11),
    );
    assert_eq!(out.removed, gone);
    assert_ne!(out.blocks[0].block_id, taken_first);
}

#[test]
fn empty_new_body_removes_every_block() {
    let old = stored(
        AC1_BODY,
        &["a00001", "a00002", "a00003", "a00004", "a00005"],
    );
    let out = rematch(&old, "");
    assert!(out.blocks.is_empty());
    assert_eq!(out.removed, old);
}

// ---- diff (AC 13-14) ---------------------------------------------------------------------------

#[test]
fn diff_against_empty_snapshot_marks_every_block_added() {
    let current = vec![
        cur("aaaaaa", 0, "Fixed the jump arc.", "person"),
        cur("bbbbbb", 1, "Captured.", "agent"),
    ];
    let d = diff(&[], &current);
    assert_eq!(d.added, current);
    assert!(d.changed.is_empty());
    assert!(d.removed.is_empty());
}

#[test]
fn diff_reports_changed_removed_and_omits_unchanged() {
    let snapshot = vec![
        snap("aaaaaa", "Same."),
        snap("bbbbbb", "Fixed the jump arc."),
        snap("cccccc", "Sleep was bad."),
    ];
    let current = vec![
        cur("aaaaaa", 0, "Same.", "person"),
        cur("bbbbbb", 1, "Fixed the jump arc today.", "person"),
        cur("dddddd", 2, "Bought groceries.", "agent"),
    ];
    let d = diff(&snapshot, &current);
    assert_eq!(d.added, vec![current[2].clone()]);
    assert_eq!(d.changed, vec![current[1].clone()]);
    assert_eq!(d.removed, vec![snapshot[2].clone()]);
    assert_eq!(d.removed[0].text, "Sleep was bad.");
}

#[test]
fn diff_lists_blocks_in_current_and_snapshot_order() {
    let snapshot = vec![
        snap("r1r1r1", "gone one"),
        snap("cccccc", "old c"),
        snap("r2r2r2", "gone two"),
        snap("eeeeee", "old e"),
    ];
    let current = vec![
        cur("a1a1a1", 0, "new one", "person"),
        cur("cccccc", 1, "new c", "person"),
        cur("a2a2a2", 2, "new two", "person"),
        cur("eeeeee", 3, "new e", "person"),
    ];
    let d = diff(&snapshot, &current);
    assert_eq!(ids(&d.added), ["a1a1a1", "a2a2a2"]);
    assert_eq!(ids(&d.changed), ["cccccc", "eeeeee"]);
    assert_eq!(
        d.removed
            .iter()
            .map(|s| s.block_id.as_str())
            .collect::<Vec<_>>(),
        ["r1r1r1", "r2r2r2"]
    );
}

#[test]
fn diff_with_unchanged_blocks_is_empty() {
    let snapshot = vec![snap("aaaaaa", "One."), snap("bbbbbb", "Two.")];
    // Reordered but unchanged: ord does not matter, only id and hash.
    let current = vec![
        cur("bbbbbb", 0, "Two.", "person"),
        cur("aaaaaa", 1, "One.", "person"),
    ];
    let d = diff(&snapshot, &current);
    assert!(d.added.is_empty() && d.changed.is_empty() && d.removed.is_empty());
}

#[test]
fn diff_with_no_current_blocks_removes_every_snapshot_block() {
    let snapshot = vec![snap("aaaaaa", "One."), snap("bbbbbb", "Two.")];
    let d = diff(&snapshot, &[]);
    assert!(d.added.is_empty() && d.changed.is_empty());
    assert_eq!(d.removed, snapshot);
}
