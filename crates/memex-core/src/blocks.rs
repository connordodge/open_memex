//! Blocks: block identity and matching.
//!
//! The pure block-identity engine for daily notes (architect ruling D12): it
//! splits the person section into blocks, hashes block text (FNV-1a-64, D2),
//! mints short block ids, matches new blocks against the stored ones so an
//! edited block keeps its id, and diffs the current blocks against a review
//! snapshot. No database access and no clock: callers (#7 save path, #11
//! review) read and write the `blocks` / `day_review_blocks` rows.

use std::cmp::Reverse;
use std::collections::{HashMap, HashSet};

/// What a block is, by the block grammar.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum BlockKind {
    /// A run of consecutive non-blank lines that is nothing else.
    Paragraph,
    /// One list item (`- `, `* `, `+ `, `<digits>. `) with its continuation lines.
    ListItem,
    /// An ATX heading line (`#`..`######` + space).
    Heading,
    /// A fenced code block, fences included.
    Code,
}

/// A block as cut from the source text by [`split`]. `text` is exactly
/// `source[start_byte..end_byte]` (UTF-8 byte offsets), without the trailing
/// newline.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SplitBlock {
    pub kind: BlockKind,
    pub start_byte: usize,
    pub end_byte: usize,
    pub text: String,
}

/// A `blocks` row (schema V5) as a plain struct, without `note_id` and
/// `created_at`, which the caller owns.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Block {
    pub block_id: String,
    pub ord: usize,
    pub start_byte: usize,
    pub end_byte: usize,
    pub text: String,
    pub content_hash: String,
    /// `person`, `agent` or `quick-entry`.
    pub source: String,
    pub created_version: i64,
}

/// A `day_review_blocks` row (schema V5) as a plain struct, without `note_id`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SnapshotBlock {
    pub block_id: String,
    pub content_hash: String,
    pub text: String,
}

/// The result of [`match_blocks`].
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct MatchOutcome {
    /// The new blocks in order (`ord` = index), each with its kept or fresh id.
    pub blocks: Vec<Block>,
    /// The old blocks that matched no new block, unchanged.
    pub removed: Vec<Block>,
}

/// The result of [`diff`]. Unchanged blocks are omitted.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct BlockDiff {
    /// Current blocks whose id is absent from the snapshot, in current order.
    pub added: Vec<Block>,
    /// Current blocks whose id is in the snapshot with a different hash, in current order.
    pub changed: Vec<Block>,
    /// Snapshot blocks whose id is absent from current, in snapshot order.
    pub removed: Vec<SnapshotBlock>,
}

/// The short-id alphabet: Crockford base32, lowercase, without i, l, o and u.
const ID_ALPHABET: &[u8; 32] = b"0123456789abcdefghjkmnpqrstvwxyz";
/// Short-id length: 6 chars, 30 bits.
const ID_LEN: usize = 6;
/// FNV-1a-64 offset basis and prime.
const FNV_OFFSET: u64 = 0xcbf2_9ce4_8422_2325;
const FNV_PRIME: u64 = 0x0000_0100_0000_01b3;
/// Minimum normalized Levenshtein similarity for a positional match.
const SIMILARITY_THRESHOLD: f64 = 0.6;
/// A fenced code block opens and closes on a line starting with this.
const FENCE: &str = "```";

/// A block [`split`] is still extending.
struct OpenBlock {
    kind: BlockKind,
    start_byte: usize,
    end_byte: usize,
    /// Indentation (bytes) of the block's first line; a list item takes
    /// continuation lines indented deeper than this.
    indent: usize,
}

impl OpenBlock {
    fn new(kind: BlockKind, start_byte: usize, end_byte: usize, indent: usize) -> Self {
        Self {
            kind,
            start_byte,
            end_byte,
            indent,
        }
    }

    fn finish(self, source: &str) -> SplitBlock {
        SplitBlock {
            kind: self.kind,
            start_byte: self.start_byte,
            end_byte: self.end_byte,
            text: source[self.start_byte..self.end_byte].to_string(),
        }
    }
}

/// Splits the person section of a daily note into blocks.
///
/// Blocks are separated by blank (empty or whitespace-only) lines. An ATX
/// heading line is always its own block; each list item is its own block
/// together with its deeper-indented, non-list continuation lines; a fenced
/// code block (an unclosed fence runs to the end of the input) is one block
/// and is never split inside; any other run of non-blank lines is one
/// paragraph. Ranges are UTF-8 byte offsets into `person`, start at the start
/// of the block's first line (indentation included) and exclude the trailing
/// newline, so they always fall on char boundaries.
pub fn split(person: &str) -> Vec<SplitBlock> {
    let mut blocks = Vec::new();
    let mut open: Option<OpenBlock> = None;
    let mut next_line = 0;
    for line in person.split('\n') {
        let first = next_line;
        let line_end = first + line.len();
        let trimmed = line.trim_start();
        let indent = line.len() - trimmed.len();
        let blank = trimmed.is_empty();
        next_line = line_end + 1;

        if let Some(code) = open.as_mut().filter(|o| o.kind == BlockKind::Code) {
            // Inside a fence: nothing splits the block. Trailing blank lines
            // of an unclosed fence stay outside its range.
            if !blank {
                code.end_byte = line_end;
            }
            if trimmed.starts_with(FENCE) {
                close(&mut open, &mut blocks, person);
            }
            continue;
        }
        if blank {
            close(&mut open, &mut blocks, person);
            continue;
        }
        if trimmed.starts_with(FENCE) {
            close(&mut open, &mut blocks, person);
            open = Some(OpenBlock::new(BlockKind::Code, first, line_end, indent));
        } else if is_heading(trimmed) {
            close(&mut open, &mut blocks, person);
            blocks.push(OpenBlock::new(BlockKind::Heading, first, line_end, indent).finish(person));
        } else if is_list_item(trimmed) {
            close(&mut open, &mut blocks, person);
            open = Some(OpenBlock::new(BlockKind::ListItem, first, line_end, indent));
        } else if let Some(block) = open
            .as_mut()
            .filter(|o| o.kind == BlockKind::Paragraph || indent > o.indent)
        {
            // Only a paragraph or a list item can be open here.
            block.end_byte = line_end;
        } else {
            close(&mut open, &mut blocks, person);
            open = Some(OpenBlock::new(
                BlockKind::Paragraph,
                first,
                line_end,
                indent,
            ));
        }
    }
    close(&mut open, &mut blocks, person);
    blocks
}

fn close(open: &mut Option<OpenBlock>, blocks: &mut Vec<SplitBlock>, source: &str) {
    if let Some(block) = open.take() {
        blocks.push(block.finish(source));
    }
}

/// `#`..`######` followed by a space (indentation already trimmed).
pub(crate) fn is_heading(line: &str) -> bool {
    let level = line.bytes().take_while(|&b| b == b'#').count();
    (1..=6).contains(&level) && line.as_bytes().get(level) == Some(&b' ')
}

/// `- `, `* `, `+ ` or `<digits>. ` (indentation already trimmed).
pub(crate) fn is_list_item(line: &str) -> bool {
    if ["- ", "* ", "+ "].iter().any(|m| line.starts_with(m)) {
        return true;
    }
    let digits = line.bytes().take_while(u8::is_ascii_digit).count();
    digits > 0 && line[digits..].starts_with(". ")
}

/// FNV-1a-64 over the UTF-8 bytes of `text`, as 16 lowercase hex chars.
///
/// Hand-written (D2): these hashes persist, so the algorithm must never
/// change with the Rust version, unlike `std::hash::DefaultHasher`.
pub fn content_hash(text: &str) -> String {
    let hash = text.bytes().fold(FNV_OFFSET, |hash, byte| {
        (hash ^ u64::from(byte)).wrapping_mul(FNV_PRIME)
    });
    format!("{hash:016x}")
}

/// Mints a 6-char lowercase Crockford base32 id that is not in `taken`,
/// drawing randomness from `rng`.
///
/// Each attempt takes one draw and uses its low 30 bits, 5 per char; a taken
/// id is discarded and the generator draws again.
pub fn short_id<R: FnMut() -> u64>(taken: &HashSet<String>, rng: &mut R) -> String {
    loop {
        let mut bits = rng();
        let id: String = (0..ID_LEN)
            .map(|_| {
                let c = char::from(ID_ALPHABET[(bits % 32) as usize]);
                bits >>= 5;
                c
            })
            .collect();
        if !taken.contains(&id) {
            return id;
        }
    }
}

/// Matches the newly split blocks against the previously stored blocks of the
/// same note. Matched blocks keep their id, `source` and `created_version`;
/// new blocks get a fresh id plus the write's `source` and `created_version`.
///
/// 1. Exact hash matches first. Each old block matches at most once. Within a
///    run of identical blocks the pairing is order-preserving (ids never swap)
///    and, among those pairings, the one with the smallest total ord distance.
/// 2. Then, among the remaining blocks, same or adjacent position
///    (|old ord − new ord| ≤ 1) with normalized Levenshtein similarity ≥ 0.6,
///    best similarity first, then the same position over an adjacent one.
/// 3. Unmatched new blocks get fresh ids that avoid every id in `old`
///    (removed ones included) and each other. Unmatched old blocks are
///    returned in `removed`, unchanged and in their input order.
pub fn match_blocks<R: FnMut() -> u64>(
    old: &[Block],
    new: &[SplitBlock],
    source: &str,
    created_version: i64,
    rng: &mut R,
) -> MatchOutcome {
    let new_hashes: Vec<String> = new.iter().map(|b| content_hash(&b.text)).collect();
    // matched[new index] = old index.
    let mut matched: Vec<Option<usize>> = vec![None; new.len()];
    let mut old_used = vec![false; old.len()];

    // 1. Exact hash matches, per group of identical blocks.
    let mut groups: HashMap<&str, (Vec<usize>, Vec<usize>)> = HashMap::new();
    for (i, b) in old.iter().enumerate() {
        groups.entry(b.content_hash.as_str()).or_default().0.push(i);
    }
    for (j, hash) in new_hashes.iter().enumerate() {
        if let Some(group) = groups.get_mut(hash.as_str()) {
            group.1.push(j);
        }
    }
    for (mut olds, news) in groups.into_values() {
        olds.sort_by_key(|&i| old[i].ord);
        let old_ords: Vec<usize> = olds.iter().map(|&i| old[i].ord).collect();
        for (a, b) in pair_in_order(&old_ords, &news) {
            matched[news[b]] = Some(olds[a]);
            old_used[olds[a]] = true;
        }
    }

    // 2. Similar text at the same or an adjacent position.
    let mut candidates: Vec<(f64, usize, usize, usize)> = Vec::new();
    for (j, nb) in new.iter().enumerate() {
        if matched[j].is_some() {
            continue;
        }
        for (i, ob) in old.iter().enumerate() {
            let distance = ob.ord.abs_diff(j);
            if !old_used[i] && distance <= 1 {
                let similarity = strsim::normalized_levenshtein(&ob.text, &nb.text);
                if similarity >= SIMILARITY_THRESHOLD {
                    candidates.push((similarity, distance, j, i));
                }
            }
        }
    }
    candidates.sort_by(|x, y| {
        y.0.total_cmp(&x.0)
            .then(x.1.cmp(&y.1))
            .then(x.2.cmp(&y.2))
            .then(x.3.cmp(&y.3))
    });
    for (_, _, j, i) in candidates {
        if matched[j].is_none() && !old_used[i] {
            matched[j] = Some(i);
            old_used[i] = true;
        }
    }

    // 3. Fresh ids for the rest; unmatched old blocks are removed.
    let mut taken: HashSet<String> = old.iter().map(|b| b.block_id.clone()).collect();
    let blocks = new
        .iter()
        .zip(new_hashes)
        .zip(matched)
        .enumerate()
        .map(|(ord, ((nb, content_hash), m))| {
            let (block_id, source, created_version) = match m {
                Some(i) => (
                    old[i].block_id.clone(),
                    old[i].source.clone(),
                    old[i].created_version,
                ),
                None => {
                    let id = short_id(&taken, rng);
                    taken.insert(id.clone());
                    (id, source.to_string(), created_version)
                }
            };
            Block {
                block_id,
                ord,
                start_byte: nb.start_byte,
                end_byte: nb.end_byte,
                text: nb.text.clone(),
                content_hash,
                source,
                created_version,
            }
        })
        .collect();
    let removed = old
        .iter()
        .zip(old_used)
        .filter(|(_, used)| !used)
        .map(|(b, _)| b.clone())
        .collect();
    MatchOutcome { blocks, removed }
}

/// One step of the [`pair_in_order`] alignment.
#[derive(Clone, Copy)]
enum Step {
    /// Pair `a[i - 1]` with `b[j - 1]`.
    Pair,
    /// Leave `a[i - 1]` unpaired.
    SkipA,
    /// Leave `b[j - 1]` unpaired.
    SkipB,
}

/// Pairs two ascending ord lists without crossing (order-preserving): as many
/// pairs as possible, then the smallest total ord distance. Returns index
/// pairs `(into a, into b)`. Ties prefer pairing over skipping.
fn pair_in_order(a: &[usize], b: &[usize]) -> Vec<(usize, usize)> {
    // Score: more pairs first, then less total distance (lower is better).
    type Score = (Reverse<usize>, usize);
    let zero: Score = (Reverse(0), 0);
    let mut score = vec![vec![zero; b.len() + 1]; a.len() + 1];
    let mut step: Vec<Vec<Option<Step>>> = vec![vec![None; b.len() + 1]; a.len() + 1];
    for i in 1..=a.len() {
        for j in 1..=b.len() {
            let (Reverse(pairs), distance) = score[i - 1][j - 1];
            let pair = (Reverse(pairs + 1), distance + a[i - 1].abs_diff(b[j - 1]));
            let (best, how) = [
                (pair, Step::Pair),
                (score[i - 1][j], Step::SkipA),
                (score[i][j - 1], Step::SkipB),
            ]
            .into_iter()
            .min_by_key(|(s, _)| *s)
            .expect("three options");
            score[i][j] = best;
            step[i][j] = Some(how);
        }
    }
    let (mut i, mut j) = (a.len(), b.len());
    let mut pairs = Vec::new();
    while let Some(how) = step[i][j] {
        match how {
            Step::Pair => {
                pairs.push((i - 1, j - 1));
                i -= 1;
                j -= 1;
            }
            Step::SkipA => i -= 1,
            Step::SkipB => j -= 1,
        }
    }
    pairs
}

/// Diffs the current blocks against a review snapshot: `added` = current ids
/// absent from the snapshot, `changed` = ids in both with a different hash
/// (both in current order), `removed` = snapshot blocks whose id is absent
/// from current (in snapshot order, carrying the snapshot text). Unchanged
/// blocks are omitted; ord plays no part.
pub fn diff(snapshot: &[SnapshotBlock], current: &[Block]) -> BlockDiff {
    let snapshot_hashes: HashMap<&str, &str> = snapshot
        .iter()
        .map(|s| (s.block_id.as_str(), s.content_hash.as_str()))
        .collect();
    let current_ids: HashSet<&str> = current.iter().map(|b| b.block_id.as_str()).collect();
    let mut out = BlockDiff::default();
    for b in current {
        match snapshot_hashes.get(b.block_id.as_str()) {
            None => out.added.push(b.clone()),
            Some(&hash) if hash != b.content_hash => out.changed.push(b.clone()),
            Some(_) => {}
        }
    }
    out.removed = snapshot
        .iter()
        .filter(|s| !current_ids.contains(s.block_id.as_str()))
        .cloned()
        .collect();
    out
}
