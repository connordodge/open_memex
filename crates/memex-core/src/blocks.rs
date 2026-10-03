//! Blocks: block identity and matching.
//!
//! The pure block-identity engine for daily notes (architect ruling D12): it
//! splits the person section into blocks, hashes block text (FNV-1a-64, D2),
//! mints short block ids, matches new blocks against the stored ones so an
//! edited block keeps its id, and diffs the current blocks against a review
//! snapshot. No database access and no clock: callers (#7 save path, #11
//! review) read and write the `blocks` / `day_review_blocks` rows.

use std::collections::HashSet;

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

/// Splits the person section of a daily note into blocks.
pub fn split(person: &str) -> Vec<SplitBlock> {
    let _ = person;
    unimplemented!("WI #6: blocks::split")
}

/// FNV-1a-64 over the UTF-8 bytes of `text`, as 16 lowercase hex chars.
pub fn content_hash(text: &str) -> String {
    let _ = text;
    unimplemented!("WI #6: blocks::content_hash")
}

/// Mints a 6-char lowercase Crockford base32 id that is not in `taken`,
/// drawing randomness from `rng`.
pub fn short_id<R: FnMut() -> u64>(taken: &HashSet<String>, rng: &mut R) -> String {
    let _ = (taken, rng);
    unimplemented!("WI #6: blocks::short_id")
}

/// Matches the newly split blocks against the previously stored blocks of the
/// same note. Matched blocks keep their id, `source` and `created_version`;
/// new blocks get a fresh id plus the write's `source` and `created_version`.
pub fn match_blocks<R: FnMut() -> u64>(
    old: &[Block],
    new: &[SplitBlock],
    source: &str,
    created_version: i64,
    rng: &mut R,
) -> MatchOutcome {
    let _ = (old, new, source, created_version, rng);
    unimplemented!("WI #6: blocks::match_blocks")
}

/// Diffs the current blocks against a review snapshot.
pub fn diff(snapshot: &[SnapshotBlock], current: &[Block]) -> BlockDiff {
    let _ = (snapshot, current);
    unimplemented!("WI #6: blocks::diff")
}
