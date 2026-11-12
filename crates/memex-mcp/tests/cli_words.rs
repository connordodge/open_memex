//! WI #430 (Spec #392 requirements 14 and 16, rulings D4, D7, D22):
//! `memex words ls|add|rm` and the `ops::words` the hosted routes share.
//! Drives the real `memex` binary against temp vaults.
//!
//! | Command | Output |
//! |---|---|
//! | `memex words ls --vault V` | `{"vault_id","words":[{"word","created_at"}]}` |
//! | `memex words add --vault V --word W` | `{"vault_id","word","changed"}` |
//! | `memex words rm --vault V --word W` | `{"vault_id","word","changed"}` |
//!
//! `learned_words` rows and `content_revision.n` are read with raw SQL while
//! the vault is closed. The help texts are pinned here against
//! `tests/golden/help/words*.txt` (D22: `cli_golden.rs` is not edited).

use std::io::Write;
use std::path::{Path, PathBuf};
use std::process::{Command, Output, Stdio};

use memex_core::{now_unix_ms, SystemClock, Vault};
use memex_mcp::ops::words::{self, AddInput, LsInput, LsOutput, RmInput, WriteOutput};
use rusqlite::Connection;
use serde_json::{json, Value};
use tempfile::TempDir;

fn run(args: &[&str], stdin_body: Option<&str>) -> Output {
    let mut child = Command::new(env!("CARGO_BIN_EXE_memex"))
        .args(args)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .expect("spawn memex");
    if let Some(body) = stdin_body {
        child
            .stdin
            .as_mut()
            .unwrap()
            .write_all(body.as_bytes())
            .unwrap();
    }
    drop(child.stdin.take());
    child.wait_with_output().expect("wait")
}

fn describe(out: &Output) -> String {
    format!(
        "exit={:?}\nstdout={}\nstderr={}",
        out.status.code(),
        String::from_utf8_lossy(&out.stdout),
        String::from_utf8_lossy(&out.stderr)
    )
}

/// Success: exit 0 and an empty stderr. Returns stdout.
fn ok_stdout(out: Output) -> String {
    assert!(
        out.status.success(),
        "expected success, got {}",
        describe(&out)
    );
    assert!(
        out.stderr.is_empty(),
        "stderr must be empty; {}",
        describe(&out)
    );
    String::from_utf8(out.stdout).expect("utf8 stdout")
}

/// One JSON line on stdout.
fn ok_json(out: Output) -> Value {
    let stdout = ok_stdout(out);
    let line = stdout.strip_suffix('\n').unwrap_or(&stdout);
    assert!(
        !line.is_empty() && !line.contains('\n'),
        "stdout must be one line: {stdout:?}"
    );
    serde_json::from_str(line).unwrap_or_else(|e| panic!("stdout not JSON ({e}): {stdout}"))
}

/// The C1 failure: exit 1, nothing on stdout, one JSON line on stderr.
/// Returns `(code, message)`.
fn c1_error(out: &Output) -> (String, String) {
    assert_eq!(
        out.status.code(),
        Some(1),
        "a failure exits 1; {}",
        describe(out)
    );
    assert!(
        out.stdout.is_empty(),
        "a failure prints nothing on stdout; {}",
        describe(out)
    );
    let stderr = String::from_utf8(out.stderr.clone()).unwrap();
    let line = stderr.strip_suffix('\n').unwrap_or(&stderr);
    assert!(
        !line.is_empty() && !line.contains('\n'),
        "stderr must be one line; {}",
        describe(out)
    );
    let v: Value = serde_json::from_str(line)
        .unwrap_or_else(|e| panic!("stderr not JSON ({e}); {}", describe(out)));
    (
        v["error"]["code"].as_str().expect("error.code").to_string(),
        v["error"]["message"]
            .as_str()
            .expect("error.message")
            .to_string(),
    )
}

/// A temp vault and the commands the tests run on it.
struct Fx {
    _dir: TempDir,
    path: String,
}

impl Fx {
    fn new() -> Self {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("vault").to_str().unwrap().to_string();
        ok_stdout(run(&["init", &path], None));
        Self { _dir: dir, path }
    }

    fn v(&self) -> &str {
        &self.path
    }

    fn vault_id(&self) -> String {
        Vault::open(&self.path).unwrap().vault_id().to_string()
    }

    fn add(&self, word: &str) -> Output {
        run(&["words", "add", "--vault", self.v(), "--word", word], None)
    }

    fn rm(&self, word: &str) -> Output {
        run(&["words", "rm", "--vault", self.v(), "--word", word], None)
    }

    fn ls(&self) -> Output {
        run(&["words", "ls", "--vault", self.v()], None)
    }

    fn db(&self) -> Connection {
        Connection::open(Path::new(&self.path).join("memex.db")).unwrap()
    }

    /// `(word_key, word, created_at)` for every row, by `word_key`.
    fn rows(&self) -> Vec<(String, String, i64)> {
        let db = self.db();
        let mut stmt = db
            .prepare("SELECT word_key, word, created_at FROM learned_words ORDER BY word_key")
            .unwrap();
        let rows = stmt
            .query_map([], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)))
            .unwrap()
            .collect::<Result<Vec<_>, _>>()
            .unwrap();
        rows
    }

    fn revision(&self) -> i64 {
        self.db()
            .query_row("SELECT n FROM content_revision WHERE id = 1", [], |r| {
                r.get(0)
            })
            .unwrap()
    }
}

/// The exact `add|rm` stdout line, keys in contract order.
fn write_line(vault_id: &str, word: &str, changed: bool) -> String {
    format!(
        "{{\"vault_id\":{},\"word\":{},\"changed\":{changed}}}\n",
        json!(vault_id),
        json!(word)
    )
}

// ---------- add ----------

#[test]
fn words_add_on_a_vault_without_the_word_prints_changed_true_and_stores_one_row() {
    let fx = Fx::new();
    let id = fx.vault_id();
    let before = now_unix_ms();
    let out = ok_stdout(fx.add("memex"));
    let after = now_unix_ms();
    assert_eq!(
        out,
        format!("{{\"vault_id\":\"{id}\",\"word\":\"memex\",\"changed\":true}}\n")
    );
    let rows = fx.rows();
    assert_eq!(rows.len(), 1, "{rows:?}");
    let (key, word, created_at) = &rows[0];
    assert_eq!((key.as_str(), word.as_str()), ("memex", "memex"));
    assert!(
        (before..=after).contains(created_at),
        "created_at {created_at} outside {before}..={after}"
    );
}

#[test]
fn words_add_of_memex_after_memex_prints_changed_false_and_moves_nothing() {
    let fx = Fx::new();
    let id = fx.vault_id();
    ok_stdout(fx.add("memex"));
    let table = fx.rows();
    let n = fx.revision();
    std::thread::sleep(std::time::Duration::from_millis(3));
    let got = ok_json(fx.add("Memex"));
    assert_eq!(
        got,
        json!({ "vault_id": id, "word": "Memex", "changed": false })
    );
    assert_eq!(fx.rows(), table, "the first spelling and stamp stay");
    assert_eq!(fx.revision(), n, "a repeat add moves no revision (D4)");
}

#[test]
fn words_add_of_emile_then_lowercase_emile_leaves_one_row_with_the_first_spelling() {
    let fx = Fx::new();
    let id = fx.vault_id();
    assert_eq!(
        ok_json(fx.add("Émile")),
        json!({ "vault_id": id, "word": "Émile", "changed": true })
    );
    assert_eq!(
        ok_json(fx.add("émile")),
        json!({ "vault_id": id, "word": "émile", "changed": false })
    );
    let rows = fx.rows();
    assert_eq!(rows.len(), 1, "{rows:?}");
    assert_eq!((rows[0].0.as_str(), rows[0].1.as_str()), ("émile", "Émile"));
}

#[test]
fn words_add_trims_the_word_and_prints_the_trimmed_word() {
    let fx = Fx::new();
    let id = fx.vault_id();
    assert_eq!(ok_stdout(fx.add("  teh  ")), write_line(&id, "teh", true));
    let rows = fx.rows();
    assert_eq!(rows.len(), 1, "{rows:?}");
    assert_eq!((rows[0].0.as_str(), rows[0].1.as_str()), ("teh", "teh"));
}

#[test]
fn words_add_rejects_empty_spaced_tabbed_and_65_character_words_with_word_invalid() {
    let fx = Fx::new();
    let n = fx.revision();
    let long = "a".repeat(65);
    for (word, what) in [
        ("", "empty"),
        ("   ", "empty after trimming"),
        ("spell check", "inner space"),
        ("spell\tcheck", "inner tab"),
        (long.as_str(), "65 characters"),
    ] {
        let (code, message) = c1_error(&fx.add(word));
        assert_eq!(code, "word_invalid", "{what}: {message}");
        assert!(!message.is_empty(), "{what}");
    }
    assert_eq!(fx.rows(), vec![], "a rejected word writes nothing");
    assert_eq!(fx.revision(), n, "a rejected word moves no revision");
}

#[test]
fn words_add_accepts_a_64_character_non_ascii_word() {
    let fx = Fx::new();
    let id = fx.vault_id();
    let word = "é".repeat(64);
    assert_eq!(ok_stdout(fx.add(&word)), write_line(&id, &word, true));
    let rows = fx.rows();
    assert_eq!(rows.len(), 1, "{rows:?}");
    assert_eq!(rows[0].1, word);
}

// ---------- rm ----------

#[test]
fn words_rm_of_memex_capitalised_removes_the_memex_row() {
    let fx = Fx::new();
    let id = fx.vault_id();
    ok_stdout(fx.add("memex"));
    ok_stdout(fx.add("teh"));
    assert_eq!(ok_stdout(fx.rm("Memex")), write_line(&id, "Memex", true));
    let keys: Vec<String> = fx.rows().into_iter().map(|r| r.0).collect();
    assert_eq!(keys, ["teh"]);
}

#[test]
fn words_rm_of_a_word_that_is_not_there_prints_changed_false_and_writes_nothing() {
    let fx = Fx::new();
    let id = fx.vault_id();
    ok_stdout(fx.add("memex"));
    let table = fx.rows();
    let n = fx.revision();
    assert_eq!(
        ok_json(fx.rm("teh")),
        json!({ "vault_id": id, "word": "teh", "changed": false })
    );
    assert_eq!(fx.rows(), table);
    assert_eq!(fx.revision(), n, "a no-op rm moves no revision");
}

// ---------- ls ----------

#[test]
fn words_ls_prints_an_empty_list_on_a_vault_with_no_learned_words() {
    let fx = Fx::new();
    let id = fx.vault_id();
    assert_eq!(
        ok_stdout(fx.ls()),
        format!("{{\"vault_id\":\"{id}\",\"words\":[]}}\n")
    );
}

#[test]
fn words_ls_prints_words_with_created_at_sorted_by_word_key() {
    let fx = Fx::new();
    let id = fx.vault_id();
    // Insertion order, `word` order (uppercase first) and `word_key` order
    // all differ: keys are apple, banana, zebra, émile (é > z).
    for w in ["zebra", "Émile", "apple", "Banana"] {
        ok_stdout(fx.add(w));
    }
    let stamp = |word: &str| {
        fx.rows()
            .into_iter()
            .find(|r| r.1 == word)
            .map(|r| r.2)
            .unwrap()
    };
    let expected: Vec<Value> = ["apple", "Banana", "zebra", "Émile"]
        .iter()
        .map(|w| json!({ "word": w, "created_at": stamp(w) }))
        .collect();
    assert_eq!(
        ok_json(fx.ls()),
        json!({ "vault_id": id, "words": expected })
    );
}

// ---------- revision (D4) ----------

#[test]
fn each_words_add_or_rm_that_changes_a_row_moves_the_revision_by_exactly_one() {
    let fx = Fx::new();
    let n0 = fx.revision();
    ok_stdout(fx.add("memex"));
    assert_eq!(fx.revision(), n0 + 1, "add");
    ok_stdout(fx.add("Émile"));
    assert_eq!(fx.revision(), n0 + 2, "second add");
    ok_stdout(fx.rm("MEMEX"));
    assert_eq!(fx.revision(), n0 + 3, "rm");
    ok_stdout(fx.rm("émile"));
    assert_eq!(fx.revision(), n0 + 4, "second rm");
    ok_stdout(fx.ls());
    assert_eq!(fx.revision(), n0 + 4, "ls writes nothing");
}

// ---------- not a vault ----------

#[test]
fn words_on_a_path_that_is_not_a_vault_gives_the_existing_vault_error_code() {
    let dir = tempfile::tempdir().unwrap();
    let missing: PathBuf = dir.path().join("nope");
    for path in [dir.path().to_str().unwrap(), missing.to_str().unwrap()] {
        let (want, _) = c1_error(&run(&["tag", "ls", "--vault", path], None));
        for args in [
            vec!["words", "ls", "--vault", path],
            vec!["words", "add", "--vault", path, "--word", "memex"],
            vec!["words", "rm", "--vault", path, "--word", "memex"],
        ] {
            let (code, message) = c1_error(&run(&args, None));
            assert_eq!(code, want, "{args:?}: {message}");
        }
    }
    assert!(!missing.exists(), "a failed words command creates no vault");
}

// ---------- help (D22) ----------

fn golden(file: &str) -> String {
    let path = Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("tests/golden/help")
        .join(format!("{file}.txt"));
    std::fs::read_to_string(&path).unwrap_or_else(|e| panic!("{}: {e}", path.display()))
}

#[test]
fn words_help_texts_match_their_goldens() {
    let mut mismatches = Vec::new();
    for (args, file) in [
        ("words", "words"),
        ("words ls", "words_ls"),
        ("words add", "words_add"),
        ("words rm", "words_rm"),
    ] {
        let mut argv: Vec<&str> = args.split(' ').collect();
        argv.push("--help");
        let got = ok_stdout(run(&argv, None));
        let want = golden(file);
        if got != want {
            mismatches.push(format!(
                "memex {args} --help\n--- golden\n{want}--- got\n{got}"
            ));
        }
        let lower = got.to_lowercase();
        for word in ["url", "server", "http", "token", "--host", "--port"] {
            assert!(
                !lower.contains(word),
                "memex {args} --help mentions {word:?}"
            );
        }
    }
    assert!(mismatches.is_empty(), "{}", mismatches.join("\n"));
}

#[test]
fn top_level_help_lists_words_after_tag() {
    let help = ok_stdout(run(&["--help"], None));
    let rows: Vec<&str> = help
        .lines()
        .map(str::trim_start)
        .filter(|l| l.starts_with("tag ") || l.starts_with("words "))
        .collect();
    assert_eq!(rows.len(), 2, "{help}");
    assert!(rows[0].starts_with("tag "), "{rows:?}");
    let about = rows[1].trim_start_matches("words").trim_start();
    assert_eq!(about, "Learn, forget or list learned words");
}

// ---------- ops (the seam W2's routes call) ----------

fn ops_vault() -> (TempDir, Vault) {
    let dir = tempfile::tempdir().unwrap();
    let vault = Vault::create(dir.path().join("vault")).unwrap();
    (dir, vault)
}

#[test]
fn ops_words_add_and_rm_return_vault_id_trimmed_word_and_changed() {
    let (_d, mut v) = ops_vault();
    let id = v.vault_id().to_string();
    let word = format!("  {}{}  ", "Mem", "ex");
    let add = |v: &mut Vault, w: &str| {
        words::add(
            v,
            AddInput {
                word: w.to_string(),
            },
            &SystemClock,
            None,
        )
        .unwrap()
    };
    let out = add(&mut v, &word);
    assert_eq!(
        out,
        WriteOutput {
            vault_id: id.clone(),
            word: "Memex".to_string(),
            changed: true,
        }
    );
    assert_eq!(
        serde_json::to_string(&out).unwrap(),
        format!(r#"{{"vault_id":"{id}","word":"Memex","changed":true}}"#)
    );
    assert!(!add(&mut v, "memex").changed, "repeat add");
    let rm = |v: &mut Vault, w: &str| {
        words::rm(
            v,
            RmInput {
                word: w.to_string(),
            },
            &SystemClock,
            None,
        )
        .unwrap()
    };
    assert_eq!(
        rm(&mut v, "MEMEX"),
        WriteOutput {
            vault_id: id.clone(),
            word: "MEMEX".to_string(),
            changed: true,
        }
    );
    assert_eq!(
        rm(&mut v, "memex"),
        WriteOutput {
            vault_id: id,
            word: "memex".to_string(),
            changed: false,
        }
    );
}

#[test]
fn ops_words_ls_returns_vault_id_and_words_sorted_by_word_key() {
    let (_d, mut v) = ops_vault();
    let id = v.vault_id().to_string();
    let empty = words::ls(&mut v, LsInput, &SystemClock, None).unwrap();
    assert_eq!(
        serde_json::to_string(&empty).unwrap(),
        format!(r#"{{"vault_id":"{id}","words":[]}}"#)
    );
    for w in ["zebra", "Émile", "apple", "Banana"] {
        words::add(
            &mut v,
            AddInput {
                word: w.to_string(),
            },
            &SystemClock,
            None,
        )
        .unwrap();
    }
    let out: LsOutput = words::ls(&mut v, LsInput, &SystemClock, None).unwrap();
    assert_eq!(out.vault_id, id);
    let spelled: Vec<&str> = out.words.iter().map(|w| w.word.as_str()).collect();
    assert_eq!(spelled, ["apple", "Banana", "zebra", "Émile"]);
    let item = serde_json::to_value(&out.words[0]).unwrap();
    assert_eq!(
        item,
        json!({ "word": "apple", "created_at": out.words[0].created_at })
    );
    assert!(out.words.iter().all(|w| w.created_at > 0));
}
