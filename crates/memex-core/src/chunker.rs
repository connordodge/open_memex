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
    let blocks = split_into_blocks(content_md);
    let mut chunks: Vec<Chunk> = Vec::new();
    let mut current: Vec<&str> = Vec::new();
    let mut current_tokens: usize = 0;

    for block in blocks {
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
/// be a subslice of `parent` (every block is: `split_into_blocks` only splits
/// and trims), so both ends lie on char boundaries.
fn byte_range(parent: &str, sub: &str) -> (usize, usize) {
    let start = sub.as_ptr() as usize - parent.as_ptr() as usize;
    (start, start + sub.len())
}

fn split_into_blocks(s: &str) -> Vec<&str> {
    s.split("\n\n")
        .map(str::trim)
        .filter(|b| !b.is_empty())
        .collect()
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
