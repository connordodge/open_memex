//! WI #430 (Spec #392 requirement 14, rulings D2, D4, D7): learned words in
//! memex-core. `learn` trims the word, keys it by the Unicode lowercase of the
//! trimmed word and inserts with `ON CONFLICT(word_key) DO NOTHING`; `unlearn`
//! deletes by that key; `list` is sorted by `word_key`. A word that is empty
//! after trimming, holds any whitespace or is over 64 characters is
//! `WordInvalid`.
//!
//! Rows and `content_revision.n` are read with raw SQL on the vault's own
//! connection, so a test sees what the triggers did.

use memex_core::words::{self, LearnedWord, WordChange};
use memex_core::{now_unix_ms, MemexError, Vault};
use tempfile::TempDir;

fn fresh() -> (TempDir, Vault) {
    let dir = tempfile::tempdir().unwrap();
    let vault = Vault::create(dir.path().join("vault")).unwrap();
    (dir, vault)
}

/// `(word_key, word, created_at)` for every row, by `word_key`.
fn rows(vault: &Vault) -> Vec<(String, String, i64)> {
    let mut stmt = vault
        .connection_ref()
        .prepare("SELECT word_key, word, created_at FROM learned_words ORDER BY word_key")
        .unwrap();
    let got = stmt
        .query_map([], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)))
        .unwrap()
        .collect::<Result<Vec<_>, _>>()
        .unwrap();
    got
}

fn revision(vault: &Vault) -> i64 {
    vault
        .connection_ref()
        .query_row("SELECT n FROM content_revision WHERE id = 1", [], |r| {
            r.get(0)
        })
        .unwrap()
}

fn change(word: &str, changed: bool) -> WordChange {
    WordChange {
        word: word.to_string(),
        changed,
    }
}

fn assert_word_invalid(got: memex_core::Result<WordChange>, what: &str) {
    match got {
        Err(MemexError::WordInvalid(msg)) => {
            assert!(!msg.is_empty(), "{what}: WordInvalid needs a message");
        }
        other => panic!("{what}: expected WordInvalid, got {other:?}"),
    }
}

#[test]
fn learn_stores_one_row_keyed_by_the_lowercase_word() {
    let (_d, mut v) = fresh();
    let before = now_unix_ms();
    let got = words::learn(&mut v, "memex").unwrap();
    let after = now_unix_ms();
    assert_eq!(got, change("memex", true));
    let rows = rows(&v);
    assert_eq!(rows.len(), 1, "{rows:?}");
    let (key, word, created_at) = &rows[0];
    assert_eq!(key, "memex");
    assert_eq!(word, "memex");
    assert!(
        (before..=after).contains(created_at),
        "created_at {created_at} outside {before}..={after}"
    );
}

#[test]
fn learn_of_a_key_already_there_writes_nothing_and_keeps_the_first_spelling() {
    let (_d, mut v) = fresh();
    assert_eq!(
        words::learn(&mut v, "memex").unwrap(),
        change("memex", true)
    );
    let table = rows(&v);
    let n = revision(&v);
    std::thread::sleep(std::time::Duration::from_millis(3));
    assert_eq!(
        words::learn(&mut v, "Memex").unwrap(),
        change("Memex", false)
    );
    assert_eq!(
        words::learn(&mut v, "memex").unwrap(),
        change("memex", false)
    );
    assert_eq!(rows(&v), table, "a repeat learn must not touch the row");
    assert_eq!(revision(&v), n, "a repeat learn must not move the revision");
}

#[test]
fn learn_keys_non_ascii_words_by_their_unicode_lowercase() {
    let (_d, mut v) = fresh();
    assert_eq!(
        words::learn(&mut v, "Émile").unwrap(),
        change("Émile", true)
    );
    assert_eq!(
        words::learn(&mut v, "émile").unwrap(),
        change("émile", false)
    );
    let rows = rows(&v);
    assert_eq!(rows.len(), 1, "{rows:?}");
    assert_eq!(rows[0].0, "émile");
    assert_eq!(rows[0].1, "Émile");
}

#[test]
fn learn_trims_the_word_before_storing_and_keying_it() {
    let (_d, mut v) = fresh();
    assert_eq!(
        words::learn(&mut v, "  teh  ").unwrap(),
        change("teh", true)
    );
    assert_eq!(
        words::learn(&mut v, "\tTeh\n").unwrap(),
        change("Teh", false)
    );
    let rows = rows(&v);
    assert_eq!(rows.len(), 1, "{rows:?}");
    assert_eq!((rows[0].0.as_str(), rows[0].1.as_str()), ("teh", "teh"));
}

#[test]
fn learn_rejects_empty_whitespace_and_over_64_character_words_with_word_invalid() {
    let (_d, mut v) = fresh();
    let n = revision(&v);
    let cases: Vec<(String, &str)> = vec![
        (String::new(), "empty"),
        ("   ".to_string(), "spaces only"),
        ("\t\n".to_string(), "tab and newline only"),
        ("spell check".to_string(), "inner space"),
        ("spell\tcheck".to_string(), "inner tab"),
        ("spell\ncheck".to_string(), "inner newline"),
        ("spell\u{00A0}check".to_string(), "inner no-break space"),
        ("spell\u{3000}check".to_string(), "inner ideographic space"),
        ("a".repeat(65), "65 ASCII characters"),
        ("é".repeat(65), "65 non-ASCII characters"),
        (
            format!("  {}  ", "b".repeat(65)),
            "65 characters after trimming",
        ),
    ];
    for (word, what) in &cases {
        assert_word_invalid(words::learn(&mut v, word), what);
    }
    assert_eq!(rows(&v), vec![], "a rejected word writes nothing");
    assert_eq!(revision(&v), n, "a rejected word moves no revision");
}

#[test]
fn learn_accepts_64_characters_counted_as_chars_not_bytes() {
    let (_d, mut v) = fresh();
    let ascii = "a".repeat(64);
    let accented = "é".repeat(64);
    assert_eq!(accented.len(), 128, "64 × é is 128 bytes");
    let padded = format!(" {} ", "c".repeat(64));
    assert_eq!(words::learn(&mut v, &ascii).unwrap(), change(&ascii, true));
    assert_eq!(
        words::learn(&mut v, &accented).unwrap(),
        change(&accented, true)
    );
    assert_eq!(
        words::learn(&mut v, &padded).unwrap(),
        change(&"c".repeat(64), true)
    );
    let keys: Vec<String> = rows(&v).into_iter().map(|r| r.0).collect();
    assert_eq!(keys, vec![ascii, "c".repeat(64), accented]);
}

#[test]
fn unlearn_deletes_by_word_key_in_any_capitalisation() {
    let (_d, mut v) = fresh();
    words::learn(&mut v, "memex").unwrap();
    words::learn(&mut v, "Émile").unwrap();
    assert_eq!(
        words::unlearn(&mut v, "Memex").unwrap(),
        change("Memex", true)
    );
    assert_eq!(
        words::unlearn(&mut v, "  ÉMILE ").unwrap(),
        change("ÉMILE", true)
    );
    assert_eq!(rows(&v), vec![]);
}

#[test]
fn unlearn_of_a_word_that_is_not_there_writes_nothing() {
    let (_d, mut v) = fresh();
    words::learn(&mut v, "memex").unwrap();
    let table = rows(&v);
    let n = revision(&v);
    assert_eq!(words::unlearn(&mut v, "teh").unwrap(), change("teh", false));
    assert_eq!(rows(&v), table);
    assert_eq!(
        revision(&v),
        n,
        "a no-op unlearn must not move the revision"
    );
}

#[test]
fn each_learn_or_unlearn_that_changes_a_row_moves_the_revision_by_exactly_one() {
    let (_d, mut v) = fresh();
    let n0 = revision(&v);
    words::learn(&mut v, "memex").unwrap();
    assert_eq!(revision(&v), n0 + 1, "learn");
    words::learn(&mut v, "teh").unwrap();
    assert_eq!(revision(&v), n0 + 2, "second learn");
    words::unlearn(&mut v, "MEMEX").unwrap();
    assert_eq!(revision(&v), n0 + 3, "unlearn");
}

#[test]
fn list_is_sorted_by_word_key_and_empty_on_a_fresh_vault() {
    let (_d, mut v) = fresh();
    assert_eq!(words::list(&v).unwrap(), Vec::<LearnedWord>::new());
    // Insertion order, `word` order (uppercase first) and `word_key` order
    // all differ: keys are apple, banana, zebra, émile (é > z).
    for w in ["zebra", "Émile", "apple", "Banana"] {
        words::learn(&mut v, w).unwrap();
    }
    let listed = words::list(&v).unwrap();
    let spelled: Vec<&str> = listed.iter().map(|w| w.word.as_str()).collect();
    assert_eq!(spelled, ["apple", "Banana", "zebra", "Émile"]);
    let stamps: Vec<(String, i64)> = rows(&v).into_iter().map(|r| (r.1, r.2)).collect();
    let listed_stamps: Vec<(String, i64)> =
        listed.into_iter().map(|w| (w.word, w.created_at)).collect();
    assert_eq!(listed_stamps, stamps, "list carries each row's created_at");
}
