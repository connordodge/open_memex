//! Learned words (Spec #392 requirement 14): words the person taught the app
//! with `Learn Spelling`, stored in the vault's `learned_words` table.

use rusqlite::params;
use serde::Serialize;

use crate::vault::{now_unix_ms, Vault};
use crate::{MemexError, Result};

/// The most characters (not bytes) a learned word may have.
const MAX_CHARS: usize = 64;

/// One learned word, as `memex words ls` prints it.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize)]
pub struct LearnedWord {
    /// The first spelling learned, trimmed.
    pub word: String,
    /// When it was learned, in Unix milliseconds.
    pub created_at: i64,
}

/// The result of [`learn`] or [`unlearn`].
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct WordChange {
    /// The trimmed word as given.
    pub word: String,
    /// True when a row was inserted or deleted.
    pub changed: bool,
}

/// Every learned word, sorted by `word_key`.
pub fn list(vault: &Vault) -> Result<Vec<LearnedWord>> {
    let mut stmt = vault
        .conn()
        .prepare("SELECT word, created_at FROM learned_words ORDER BY word_key")?;
    let rows = stmt.query_map([], |r| {
        Ok(LearnedWord {
            word: r.get(0)?,
            created_at: r.get(1)?,
        })
    })?;
    Ok(rows.collect::<rusqlite::Result<_>>()?)
}

/// Learns `word`, trimmed and keyed by its Unicode lowercase. A word whose
/// key is already there writes nothing and keeps the first spelling. An empty
/// word, one with whitespace or one over 64 characters is `WordInvalid`.
pub fn learn(vault: &mut Vault, word: &str) -> Result<WordChange> {
    let word = word.trim();
    let count = word.chars().count();
    if count == 0 || count > MAX_CHARS || word.chars().any(char::is_whitespace) {
        return Err(MemexError::WordInvalid(format!(
            "a learned word must be 1 to {MAX_CHARS} characters with no whitespace, got {word:?}"
        )));
    }
    let n = vault.conn().execute(
        "INSERT INTO learned_words (word_key, word, created_at) VALUES (?1, ?2, ?3)
         ON CONFLICT(word_key) DO NOTHING",
        params![word.to_lowercase(), word, now_unix_ms()],
    )?;
    Ok(WordChange {
        word: word.to_string(),
        changed: n == 1,
    })
}

/// Forgets the word whose key matches the trimmed `word`, in any
/// capitalisation. A word that is not there writes nothing.
pub fn unlearn(vault: &mut Vault, word: &str) -> Result<WordChange> {
    let word = word.trim();
    let n = vault.conn().execute(
        "DELETE FROM learned_words WHERE word_key = ?1",
        params![word.to_lowercase()],
    )?;
    Ok(WordChange {
        word: word.to_string(),
        changed: n == 1,
    })
}
