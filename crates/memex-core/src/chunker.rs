//! Lightweight markdown chunker: splits on heading + paragraph boundaries
//! and packs into chunks targeting roughly TARGET_TOKENS per chunk.
//!
//! Token counting here is an approximation — words / 0.75 — adequate for
//! prototype indexing decisions. Replace with a real tokenizer if needed.
//!
//! Every chunk records its UTF-8 byte range in the input (D25). A chunk of
//! whole blocks spans from its first block's first byte to its last block's
//! last byte, and its content is exactly that slice. Sentence sub-chunks of a
//! long block all carry the range of the (trimmed) block they came from.
//!
//! A blank-line block made only of transclusion tokens (`![[…]]`, CONTRACTS
//! C4) and whitespace is in no chunk, and it ends the chunk before it (Spec
//! #391 req 2).

use crate::link_extractor;

const TARGET_TOKENS: usize = 380;
const MAX_TOKENS: usize = 600;

#[derive(Debug, Clone)]
pub struct Chunk {
    pub ord: i64,
    pub content: String,
    pub token_count: i64,
    /// UTF-8 byte offset into the chunked input where this chunk starts (D25).
    pub start_byte: usize,
    /// UTF-8 byte offset one past the end of this chunk in the input (D25).
    pub end_byte: usize,
}

pub fn chunk(content_md: &str) -> Vec<Chunk> {
    if content_md.trim().is_empty() {
        return Vec::new();
    }
    let mut chunks: Vec<Chunk> = Vec::new();
    let mut current: Vec<&str> = Vec::new();
    let mut current_tokens: usize = 0;

    for (_, block, transclusion_only) in blocks(content_md) {
        // A transclusion-only block ends the current chunk and joins none.
        if transclusion_only {
            if !current.is_empty() {
                push_chunk(&mut chunks, content_md, &current, current_tokens);
                current.clear();
                current_tokens = 0;
            }
            continue;
        }
        let bt = approx_tokens(block);
        // Single block bigger than MAX_TOKENS: split it on sentences.
        if bt > MAX_TOKENS {
            // flush current first
            if !current.is_empty() {
                push_chunk(&mut chunks, content_md, &current, current_tokens);
                current.clear();
                current_tokens = 0;
            }
            let range = byte_range(content_md, block);
            for s in split_long_block(block) {
                let st = approx_tokens(&s);
                push_chunk_owned(&mut chunks, &s, st, range);
            }
            continue;
        }

        // If adding this block would exceed TARGET_TOKENS and we already
        // have something, flush first.
        if current_tokens + bt > TARGET_TOKENS && !current.is_empty() {
            push_chunk(&mut chunks, content_md, &current, current_tokens);
            current.clear();
            current_tokens = 0;
        }
        current.push(block);
        current_tokens += bt;
    }
    if !current.is_empty() {
        push_chunk(&mut chunks, content_md, &current, current_tokens);
    }
    chunks
}

/// The blank-line blocks of `input`, each trimmed, as `(offset, text)` with
/// `offset` the UTF-8 byte offset of `text` in `input`. Transclusion-only
/// blocks are left out (Spec #391 req 2). The chunker's own splitter.
pub fn split_blocks(input: &str) -> Vec<(usize, &str)> {
    blocks(input)
        .filter(|(_, _, transclusion_only)| !transclusion_only)
        .map(|(offset, text, _)| (offset, text))
        .collect()
}

/// The non-empty trimmed blank-line blocks of `input` as
/// `(offset, text, transclusion_only)`, `offset` being the UTF-8 byte offset
/// of `text` in `input`. The one splitter behind [`chunk`] and
/// [`split_blocks`].
fn blocks(input: &str) -> impl Iterator<Item = (usize, &str, bool)> {
    input
        .split("\n\n")
        .map(str::trim)
        .filter(|b| !b.is_empty())
        .map(move |b| (byte_range(input, b).0, b, is_transclusion_only(b)))
}

/// Whether `block` holds at least one transclusion token and nothing but
/// whitespace outside its tokens.
fn is_transclusion_only(block: &str) -> bool {
    let tokens = link_extractor::parse_transclusions(block);
    if tokens.is_empty() {
        return false;
    }
    let mut at = 0;
    for t in &tokens {
        if !block[at..t.start].trim().is_empty() {
            return false;
        }
        at = t.end;
    }
    block[at..].trim().is_empty()
}

/// Pushes one chunk made of whole `blocks` (non-empty subslices of `input`,
/// in order). Its range runs from the first block's start to the last
/// block's end, and its content is that slice of `input`.
fn push_chunk(chunks: &mut Vec<Chunk>, input: &str, blocks: &[&str], tokens: usize) {
    let (start_byte, _) = byte_range(input, blocks[0]);
    let (_, end_byte) = byte_range(input, blocks[blocks.len() - 1]);
    chunks.push(Chunk {
        ord: chunks.len() as i64,
        content: input[start_byte..end_byte].to_string(),
        token_count: tokens as i64,
        start_byte,
        end_byte,
    });
}

fn push_chunk_owned(
    chunks: &mut Vec<Chunk>,
    block: &str,
    tokens: usize,
    (start_byte, end_byte): (usize, usize),
) {
    let content = block.trim().to_string();
    if content.is_empty() {
        return;
    }
    chunks.push(Chunk {
        ord: chunks.len() as i64,
        content,
        token_count: tokens as i64,
        start_byte,
        end_byte,
    });
}

/// The `[start, end)` UTF-8 byte range of `sub` within `parent`. `sub` must
/// be a subslice of `parent` (every block is: [`blocks`] only splits and
/// trims), so both ends lie on char boundaries.
fn byte_range(parent: &str, sub: &str) -> (usize, usize) {
    let start = sub.as_ptr() as usize - parent.as_ptr() as usize;
    (start, start + sub.len())
}

fn split_long_block(s: &str) -> Vec<String> {
    // Sentence-ish split. Keep it simple — period/question/exclamation
    // followed by whitespace.
    let mut out: Vec<String> = Vec::new();
    let mut current = String::new();
    let mut current_tokens: usize = 0;
    for sentence in pseudo_sentences(s) {
        let st = approx_tokens(sentence);
        if current_tokens + st > TARGET_TOKENS && !current.is_empty() {
            out.push(current.trim().to_string());
            current = String::new();
            current_tokens = 0;
        }
        if !current.is_empty() {
            current.push(' ');
        }
        current.push_str(sentence.trim());
        current_tokens += st;
    }
    if !current.trim().is_empty() {
        out.push(current.trim().to_string());
    }
    if out.is_empty() {
        out.push(s.trim().to_string());
    }
    out
}

fn pseudo_sentences(s: &str) -> Vec<&str> {
    let mut out = Vec::new();
    let bytes = s.as_bytes();
    let mut start = 0usize;
    let mut i = 0usize;
    while i < bytes.len() {
        let b = bytes[i];
        if (b == b'.' || b == b'!' || b == b'?')
            && i + 1 < bytes.len()
            && (bytes[i + 1] == b' ' || bytes[i + 1] == b'\n')
        {
            out.push(&s[start..=i]);
            start = i + 1;
            while start < bytes.len() && (bytes[start] == b' ' || bytes[start] == b'\n') {
                start += 1;
            }
            i = start;
            continue;
        }
        i += 1;
    }
    if start < bytes.len() {
        out.push(&s[start..]);
    }
    out
}

fn approx_tokens(s: &str) -> usize {
    let words = s.split_whitespace().count();
    // ~1.33 tokens per word for English.
    ((words as f32) * 1.33).ceil() as usize
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn empty_input_yields_no_chunks() {
        assert!(chunk("").is_empty());
        assert!(chunk("   \n\n   \n").is_empty());
    }

    #[test]
    fn small_note_yields_single_chunk() {
        let md = "# Hello\n\nThis is a small note with one paragraph.";
        let cs = chunk(md);
        assert_eq!(cs.len(), 1);
        assert!(cs[0].content.contains("small note"));
        assert!(cs[0].content.contains("Hello"));
    }

    #[test]
    fn multi_paragraph_packs_until_target() {
        let para = "lorem ipsum dolor sit amet ".repeat(50); // ~250 tokens
        let md = format!("{para}\n\n{para}\n\n{para}");
        let cs = chunk(&md);
        // 3 paragraphs of ~330 tokens each => splits into multiple chunks
        assert!(cs.len() >= 2, "expected >=2 chunks, got {}", cs.len());
        for c in &cs {
            assert!(c.token_count <= MAX_TOKENS as i64);
        }
    }

    #[test]
    fn very_long_paragraph_is_sentence_split() {
        // single paragraph far exceeding MAX_TOKENS — must split internally.
        let s: String = (0..200)
            .map(|i| format!("Sentence number {i} has some words in it."))
            .collect::<Vec<_>>()
            .join(" ");
        let cs = chunk(&s);
        assert!(cs.len() >= 2);
        for c in &cs {
            assert!(c.token_count <= MAX_TOKENS as i64);
        }
    }

    #[test]
    fn chunks_have_monotonically_increasing_ord() {
        let para = "alpha beta gamma delta epsilon ".repeat(80);
        let md = format!("{para}\n\n{para}\n\n{para}\n\n{para}");
        let cs = chunk(&md);
        for (i, c) in cs.iter().enumerate() {
            assert_eq!(c.ord, i as i64);
        }
    }
}
