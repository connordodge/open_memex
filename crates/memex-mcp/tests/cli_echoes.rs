//! WI #423 (Spec #391 requirements 14, 16 and 17, rulings D6, D22, L5):
//! `memex echoes --vault <path> --note-id <id> [--limit <n>] [--allow-download]`.
//! Drives the real `memex` binary against temp vaults.
//!
//! - Success: one bare JSON object on stdout, `{"echoes":[{note_id,
//!   note_title, note_role, day, passage, start_byte, note_updated_at}],
//!   "reason", "pending"}`, the same value `memex_core::echoes::echoes`
//!   answers (`others_cap` 64).
//! - Failure: exit 1, nothing on stdout, one C1 JSON line on stderr.
//! - `--limit` takes 1-20 and defaults to 8; out of range is
//!   `invalid_argument` with the message `invalid limit: <n> (1 to 20)`.
//! - The model cache is `model_cache_dir(<vault>)` (`<vault>/.memex/models`).
//!   Without `--allow-download`, when embedding is needed and the model is
//!   not cached, the command fails with `model_not_downloaded` before any
//!   network access; a read that needs no embedding succeeds with no model.
//!
//! No test downloads or runs the real model. Every child gets `HF_ENDPOINT`
//! pointed at a [`Tripwire`] (a local port that counts and drops every
//! connection) and runs with `HF_HOME` unset, so "no network access" is an
//! exact count and the cache fastembed reads is the vault's. Vectors are
//! written straight into `chunk_vec` (384-d, the BGE-small width), so a
//! vault whose chunks are all embedded and single-block needs no model.
//! Query vector `Q` is axis 0; `near(0, side, s)` has cosine `s` to `Q`.
//!
//! The help text is pinned here against `tests/golden/help/echoes.txt`
//! (D22: `cli_golden.rs` and `memex.txt` are not edited).

use std::fs;
use std::path::{Path, PathBuf};
use std::process::{Command, Output, Stdio};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::Arc;

use memex_core::echoes::echoes;
use memex_core::embedder::{FastEmbedder, TableEmbedder};
use memex_core::indexer;
use memex_core::notes::{create_note_as, CreateNote};
use memex_core::schema;
use memex_core::{Caller, Vault};
use memex_mcp::state::model_cache_dir;
use rusqlite::{params, Connection};
use serde_json::{json, Value};
use tempfile::TempDir;

/// The BGE-small-en-v1.5 vector width.
const DIM: usize = 384;
/// A valid ULID no test vault has.
const UNKNOWN: &str = "01J9Z8Y7X6W5V4T3S2R1Q0P9N8";
/// The CLI's `others_cap` (Spec #391 req 11.1, "64 locally").
const CLI_OTHERS_CAP: usize = 64;

// ---------------------------------------------------------------- vectors

/// The unit vector on `axis`.
fn e(axis: usize) -> Vec<f32> {
    let mut v = vec![0.0; DIM];
    v[axis] = 1.0;
    v
}

/// A unit vector with cosine `s` to `e(axis)`, the rest on `e(side)`.
fn near(axis: usize, side: usize, s: f32) -> Vec<f32> {
    assert_ne!(axis, side);
    let mut v = vec![0.0; DIM];
    v[axis] = s;
    v[side] = (1.0 - s * s).sqrt();
    v
}

fn le_bytes(v: &[f32]) -> Vec<u8> {
    v.iter().flat_map(|f| f.to_le_bytes()).collect()
}

// ---------------------------------------------------------------- network tripwire

/// A local port that counts and drops every connection, for `HF_ENDPOINT`.
/// Any hf-hub request fails at once and is counted.
struct Tripwire {
    url: String,
    hits: Arc<AtomicUsize>,
}

impl Tripwire {
    fn start() -> Self {
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let url = format!("http://{}", listener.local_addr().unwrap());
        let hits = Arc::new(AtomicUsize::new(0));
        let h = hits.clone();
        std::thread::spawn(move || {
            for s in listener.incoming() {
                h.fetch_add(1, Ordering::SeqCst);
                drop(s);
            }
        });
        Self { url, hits }
    }

    fn hits(&self) -> usize {
        self.hits.load(Ordering::SeqCst)
    }
}

// ---------------------------------------------------------------- the binary

/// `memex <args…>` with `HF_ENDPOINT` at `hub` and `HF_HOME` unset.
fn memex(args: &[&str], hub: &Tripwire) -> Output {
    Command::new(env!("CARGO_BIN_EXE_memex"))
        .args(args)
        .env("HF_ENDPOINT", &hub.url)
        .env_remove("HF_HOME")
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .output()
        .expect("run memex")
}

/// `memex echoes --vault <vault> --note-id <note> <extra…>`.
fn run_echoes(vault: &Path, note: &str, extra: &[&str], hub: &Tripwire) -> Output {
    let mut args = vec![
        "echoes",
        "--vault",
        vault.to_str().unwrap(),
        "--note-id",
        note,
    ];
    args.extend_from_slice(extra);
    memex(&args, hub)
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
fn ok_stdout(out: &Output) -> String {
    assert!(
        out.status.success(),
        "expected success, got {}",
        describe(out)
    );
    assert!(
        out.stderr.is_empty(),
        "stderr must be empty; {}",
        describe(out)
    );
    String::from_utf8(out.stdout.clone()).expect("utf8 stdout")
}

/// One bare JSON object on one stdout line.
fn ok_json(out: &Output) -> Value {
    let stdout = ok_stdout(out);
    let line = stdout.strip_suffix('\n').unwrap_or(&stdout);
    assert!(
        !line.is_empty() && !line.contains('\n'),
        "stdout must be one line: {stdout:?}"
    );
    let v: Value =
        serde_json::from_str(line).unwrap_or_else(|e| panic!("stdout not JSON ({e}): {stdout}"));
    assert!(v.is_object(), "a bare JSON object: {v}");
    v
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

// ---------------------------------------------------------------- vaults

/// A temp vault built with memex-core, closed before the binary runs.
struct Vx {
    _dir: TempDir,
    path: PathBuf,
    vault: Option<Vault>,
}

impl Vx {
    fn new() -> Self {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("vault");
        let vault = Vault::create(&path).unwrap();
        schema::ensure_vector_table(vault.connection_ref(), DIM).unwrap();
        Self {
            _dir: dir,
            path,
            vault: Some(vault),
        }
    }

    fn v(&mut self) -> &mut Vault {
        self.vault.as_mut().expect("the vault is open")
    }

    fn conn(&self) -> &Connection {
        self.vault
            .as_ref()
            .expect("the vault is open")
            .connection_ref()
    }

    /// Creates a note as the person and indexes it with no embedder.
    fn create(&mut self, title: &str, body: &str, fm: Option<Value>) -> String {
        let note = create_note_as(
            self.v(),
            CreateNote {
                title: Some(title.into()),
                content_md: body.into(),
                frontmatter: fm,
            },
            Caller::Person,
        )
        .unwrap_or_else(|e| panic!("create {title}: {e}"));
        indexer::reindex_note(
            self.v().connection_mut(),
            note.id.as_str(),
            &note.content_md,
            None,
        )
        .unwrap();
        note.id.as_str().to_string()
    }

    fn plain(&mut self, title: &str, body: &str) -> String {
        self.create(title, body, None)
    }

    fn topic(&mut self, title: &str, body: &str) -> String {
        self.create(title, body, Some(json!({ "role": "topic" })))
    }

    fn daily(&mut self, date: &str, body: &str) -> String {
        self.create(date, body, Some(json!({ "role": "daily" })))
    }

    fn chunk_ids(&self, note: &str) -> Vec<String> {
        let mut stmt = self
            .conn()
            .prepare("SELECT id FROM chunks WHERE note_id = ? ORDER BY ord")
            .unwrap();
        let ids = stmt
            .query_map([note], |r| r.get(0))
            .unwrap()
            .collect::<rusqlite::Result<Vec<String>>>()
            .unwrap();
        ids
    }

    /// Writes `v` as the vector of every chunk of `note` (it has at least
    /// one).
    fn embed(&self, note: &str, v: &[f32]) {
        let ids = self.chunk_ids(note);
        assert!(!ids.is_empty(), "note {note} has chunks");
        for id in ids {
            self.conn()
                .execute(
                    "INSERT INTO chunk_vec (chunk_id, embedding) VALUES (?, ?)",
                    params![id, le_bytes(v)],
                )
                .unwrap();
        }
    }

    fn set_start_byte(&self, note: &str, start: Option<i64>) {
        let n = self
            .conn()
            .execute(
                "UPDATE chunks SET start_byte = ? WHERE note_id = ?",
                params![start, note],
            )
            .unwrap();
        assert!(n > 0, "note {note} has chunks");
    }

    fn updated_at(&self, note: &str) -> i64 {
        self.conn()
            .query_row("SELECT updated_at FROM notes WHERE id = ?", [note], |r| {
                r.get(0)
            })
            .unwrap()
    }

    /// `(chunks, embedded)` of the open vault.
    fn counts(&self) -> (i64, i64) {
        self.conn()
            .query_row(
                "SELECT (SELECT COUNT(*) FROM chunks),
                        (SELECT COUNT(*) FROM chunk_vec v JOIN chunks c ON c.id = v.chunk_id)",
                [],
                |r| Ok((r.get(0)?, r.get(1)?)),
            )
            .unwrap()
    }

    /// Closes the vault so the binary owns it; returns its folder.
    fn close(&mut self) -> PathBuf {
        drop(self.vault.take());
        self.path.clone()
    }

    fn reopen(&mut self) {
        self.vault = Some(Vault::open(&self.path).unwrap());
    }
}

/// What `memex_core::echoes::echoes` answers for `note` on the (closed)
/// vault at `path`, as JSON, with an embedder that has no vector for any
/// text (so the comparison also proves the read needed none).
fn core_echoes(path: &Path, note: &str, limit: usize) -> Value {
    let mut vault = Vault::open(path).unwrap();
    let embedder = TableEmbedder::new(DIM);
    let mut conn: &mut Connection = vault.connection_mut();
    let got = echoes(&mut conn, &embedder, note, limit, CLI_OTHERS_CAP)
        .unwrap_or_else(|e| panic!("core echoes of {note}: {e}"));
    assert_eq!(embedder.calls(), 0, "the core read needed no embedding");
    serde_json::to_value(got).unwrap()
}

/// The pre-embedded vault of AC 1: every chunk single-block and embedded.
struct Embedded {
    vx: Vx,
    open: String,
    daily: String,
    topic: String,
    plain: String,
    topic_body: String,
}

/// Body of the topic echo: blank lines before its only block, so its
/// passage starts past byte 0 (offsets index the full body, req 1).
const TOPIC_BODY: &str = "\n\n\nA topic passage about the jump arc.";

fn embedded_vault() -> Embedded {
    let mut vx = Vx::new();
    let open = vx.plain("Open Note", "The open passage about the jump arc.");
    let daily = vx.daily("2026-10-01", "A daily passage about the jump arc.");
    let topic = vx.topic("Topic A", TOPIC_BODY);
    let plain = vx.plain("Plain B", "A plain passage about the jump arc.");
    let far = vx.plain("Far C", "Nothing like it at all.");
    vx.embed(&open, &e(0));
    vx.embed(&daily, &near(0, 1, 0.95));
    vx.embed(&topic, &near(0, 2, 0.90));
    vx.embed(&plain, &near(0, 3, 0.85));
    vx.embed(&far, &near(0, 4, 0.50));
    // A chunk indexed before byte offsets existed.
    vx.set_start_byte(&plain, None);
    let (chunks, embedded) = vx.counts();
    assert_eq!(chunks, embedded, "every chunk is embedded");
    Embedded {
        vx,
        open,
        daily,
        topic,
        plain,
        topic_body: TOPIC_BODY.to_string(),
    }
}

/// The echoes [`embedded_vault`] is designed to answer for its open note.
fn designed_echoes(fx: &Embedded) -> Value {
    let topic_start = fx
        .topic_body
        .find("A topic passage")
        .expect("topic passage");
    json!({
        "echoes": [
            {
                "note_id": fx.daily,
                "note_title": "2026-10-01",
                "note_role": "daily",
                "day": "2026-10-01",
                "passage": "A daily passage about the jump arc.",
                "start_byte": 0,
                "note_updated_at": fx.vx.updated_at(&fx.daily),
            },
            {
                "note_id": fx.topic,
                "note_title": "Topic A",
                "note_role": "topic",
                "day": null,
                "passage": "A topic passage about the jump arc.",
                "start_byte": topic_start,
                "note_updated_at": fx.vx.updated_at(&fx.topic),
            },
            {
                "note_id": fx.plain,
                "note_title": "Plain B",
                "note_role": null,
                "day": null,
                "passage": "A plain passage about the jump arc.",
                "start_byte": null,
                "note_updated_at": fx.vx.updated_at(&fx.plain),
            },
        ],
        "reason": null,
        "pending": 0,
    })
}

/// A vault whose open note has `n` single-block, embedded echo candidates,
/// `Cand 01` (best) to `Cand <n>`, all above the threshold.
fn many_candidates(n: usize) -> (Vx, String, Vec<String>) {
    let mut vx = Vx::new();
    let open = vx.plain("Open Note", "The open passage.");
    vx.embed(&open, &e(0));
    let cands = (1..=n)
        .map(|i| {
            let id = vx.plain(&format!("Cand {i:02}"), &format!("Candidate passage {i}."));
            vx.embed(&id, &near(0, 1, 0.95 - 0.01 * i as f32));
            id
        })
        .collect();
    (vx, open, cands)
}

fn echo_ids(v: &Value) -> Vec<String> {
    v["echoes"]
        .as_array()
        .unwrap_or_else(|| panic!("echoes is an array: {v}"))
        .iter()
        .map(|e| e["note_id"].as_str().unwrap().to_string())
        .collect()
}

/// A vault whose open note's only chunk has no vector yet.
fn unembedded_vault() -> (Vx, String) {
    let mut vx = Vx::new();
    let open = vx.plain("Open Note", "The open passage, not embedded yet.");
    let other = vx.plain("Other", "Another passage.");
    vx.embed(&other, &e(0));
    (vx, open)
}

/// The fastembed repo folder of BGE-small-en-v1.5 under a model cache.
fn model_repo_dir(cache: &Path) -> PathBuf {
    cache.join("models--Xenova--bge-small-en-v1.5")
}

/// A complete, fake BGE-small-en-v1.5 cache under `cache` in hf-hub's layout
/// (`refs/main` -> a snapshot holding every file fastembed reads, D39).
/// `FastEmbedder::is_cached` reads it as cached; loading it fails on the
/// fake bytes, with no network access.
fn write_fake_cached_model(cache: &Path) {
    const COMMIT: &str = "5c38ec7c405ec4b44b94cc5a9bb96e735b38267a";
    let repo = model_repo_dir(cache);
    for file in [
        "onnx/model.onnx",
        "tokenizer.json",
        "config.json",
        "special_tokens_map.json",
        "tokenizer_config.json",
    ] {
        let path = repo.join("snapshots").join(COMMIT).join(file);
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        fs::write(&path, format!("fake {file}\n")).unwrap();
    }
    fs::create_dir_all(repo.join("refs")).unwrap();
    fs::write(repo.join("refs/main"), COMMIT).unwrap();
}

// ---------------------------------------------------------------- AC 1

#[test]
fn wi423_embedded_vault_core_result_is_the_designed_one() {
    // Guards the fixture, not the command: the core result for the AC 1
    // vault has every req 14 field in each of its forms.
    let mut fx = embedded_vault();
    let want = designed_echoes(&fx);
    let path = fx.vx.close();
    assert_eq!(core_echoes(&path, &fx.open, 8), want);
}

#[test]
fn echoes_on_a_pre_embedded_vault_prints_the_core_result_as_one_json_object() {
    let mut fx = embedded_vault();
    let want = designed_echoes(&fx);
    let path = fx.vx.close();
    let hub = Tripwire::start();

    let got = ok_json(&run_echoes(&path, &fx.open, &[], &hub));

    // Exactly the three top-level keys, and every req 14 field per echo,
    // with no score.
    let keys: Vec<&str> = got
        .as_object()
        .unwrap()
        .keys()
        .map(String::as_str)
        .collect();
    assert_eq!(
        {
            let mut k = keys.clone();
            k.sort();
            k
        },
        vec!["echoes", "pending", "reason"],
        "{got}"
    );
    for echo in got["echoes"].as_array().expect("echoes array") {
        let mut fields: Vec<&str> = echo
            .as_object()
            .unwrap()
            .keys()
            .map(String::as_str)
            .collect();
        fields.sort();
        assert_eq!(
            fields,
            vec![
                "day",
                "note_id",
                "note_role",
                "note_title",
                "note_updated_at",
                "passage",
                "start_byte"
            ],
            "{echo}"
        );
    }
    assert_eq!(got, want, "the designed echoes");
    assert_eq!(got, core_echoes(&path, &fx.open, 8), "the core result");
    assert_eq!(hub.hits(), 0, "nothing contacted HF_ENDPOINT");
}

#[test]
fn echoes_reports_empty_note_and_pending_like_the_core() {
    // `reason` and `pending` come from the core result: a note with no
    // chunks is `empty_note`, and `pending` counts unembedded chunks left.
    let mut vx = Vx::new();
    let empty = vx.daily("2026-10-02", "");
    assert!(
        vx.chunk_ids(&empty).is_empty(),
        "an empty daily has no chunks"
    );
    let path = vx.close();
    let hub = Tripwire::start();
    let got = ok_json(&run_echoes(&path, &empty, &[], &hub));
    assert_eq!(
        got,
        json!({ "echoes": [], "reason": "empty_note", "pending": 0 }),
        "{got}"
    );
    assert_eq!(got, core_echoes(&path, &empty, 8));
}

// ---------------------------------------------------------------- AC 2

#[test]
fn limit_0_and_21_fail_with_invalid_argument() {
    let (mut vx, open, _) = many_candidates(3);
    let path = vx.close();
    let hub = Tripwire::start();
    for bad in ["0", "21"] {
        let out = run_echoes(&path, &open, &["--limit", bad], &hub);
        let (code, message) = c1_error(&out);
        assert_eq!(code, "invalid_argument", "--limit {bad}: {message}");
        assert_eq!(
            message,
            format!("invalid limit: {bad} (1 to 20)"),
            "--limit {bad}"
        );
    }
    assert_eq!(hub.hits(), 0);
}

#[test]
fn without_limit_at_most_8_echoes_are_returned_and_1_and_20_are_accepted() {
    let (mut vx, open, cands) = many_candidates(21);
    let path = vx.close();
    let hub = Tripwire::start();

    let default = ok_json(&run_echoes(&path, &open, &[], &hub));
    assert_eq!(echo_ids(&default), cands[..8].to_vec(), "default limit 8");

    let one = ok_json(&run_echoes(&path, &open, &["--limit", "1"], &hub));
    assert_eq!(echo_ids(&one), cands[..1].to_vec(), "--limit 1");

    let twenty = ok_json(&run_echoes(&path, &open, &["--limit", "20"], &hub));
    assert_eq!(echo_ids(&twenty), cands[..20].to_vec(), "--limit 20");
    assert_eq!(twenty, core_echoes(&path, &open, 20));
    assert_eq!(hub.hits(), 0);
}

// ---------------------------------------------------------------- AC 3

#[test]
fn a_missing_note_fails_with_a_c1_not_found_line_on_stderr() {
    let (mut vx, _) = unembedded_vault();
    let path = vx.close();
    let hub = Tripwire::start();
    let out = run_echoes(&path, UNKNOWN, &[], &hub);
    let (code, message) = c1_error(&out);
    assert_eq!(code, "not_found", "{message}");
    assert_eq!(message, format!("not found: note {UNKNOWN}"));
    assert_eq!(hub.hits(), 0, "not_found needs no model");
}

// ---------------------------------------------------------------- AC 4

#[test]
fn unembedded_chunks_with_no_cached_model_and_no_allow_download_fail_with_model_not_downloaded_and_no_network(
) {
    let (mut vx, open) = unembedded_vault();
    let path = vx.close();
    let cache = model_cache_dir(&path);
    assert!(!FastEmbedder::is_cached(&cache), "no model is cached");
    let hub = Tripwire::start();

    let out = run_echoes(&path, &open, &[], &hub);
    let (code, message) = c1_error(&out);
    assert_eq!(code, "model_not_downloaded", "{message}");
    assert_eq!(message, "embedding model not downloaded");
    assert_eq!(hub.hits(), 0, "nothing contacted HF_ENDPOINT");
    assert!(
        !model_repo_dir(&cache).exists(),
        "nothing was downloaded into {}",
        cache.display()
    );
    vx.reopen();
    assert_eq!(vx.counts(), (2, 1), "no vector was written");
}

#[test]
fn another_notes_unembedded_chunk_needs_the_model_so_the_cli_others_cap_is_not_zero() {
    // The open note is fully embedded; only another note's chunk has no
    // vector. Whether the read embeds it depends on `others_cap` alone: the
    // CLI's is 64, so it needs the model and fails with `model_not_downloaded`
    // (a cap of 0 would succeed with `pending: 1`, req 11.1).
    let mut vx = Vx::new();
    let open = vx.plain("Open Note", "The open passage about the jump arc.");
    let other = vx.plain("Other Note", "Another passage, not embedded yet.");
    vx.embed(&open, &e(0));
    assert!(!vx.chunk_ids(&other).is_empty());
    assert_eq!(vx.counts(), (2, 1), "only the other note is unembedded");
    let path = vx.close();
    let cache = model_cache_dir(&path);
    assert!(!FastEmbedder::is_cached(&cache), "no model is cached");

    // The case depends on the cap: with 0 the core embeds nothing and leaves
    // the chunk pending; with the CLI's 64 it tries to embed it.
    {
        let mut v = Vault::open(&path).unwrap();
        let embedder = TableEmbedder::new(DIM);
        let mut conn: &mut Connection = v.connection_mut();
        let capped = echoes(&mut conn, &embedder, &open, 8, 0).unwrap();
        assert_eq!(embedder.calls(), 0, "others_cap 0 embeds nothing");
        assert_eq!(serde_json::to_value(&capped).unwrap()["pending"], 1);
        let uncapped = echoes(&mut conn, &embedder, &open, 8, CLI_OTHERS_CAP);
        assert!(uncapped.is_err(), "others_cap 64 tries to embed the chunk");
        assert_eq!(embedder.calls(), 1, "others_cap 64 embeds the chunk");
    }

    let hub = Tripwire::start();
    let out = run_echoes(&path, &open, &[], &hub);
    let (code, message) = c1_error(&out);
    assert_eq!(code, "model_not_downloaded", "{message}");
    assert_eq!(message, "embedding model not downloaded");
    assert_eq!(hub.hits(), 0, "nothing contacted HF_ENDPOINT");
    assert!(
        !model_repo_dir(&cache).exists(),
        "nothing was downloaded into {}",
        cache.display()
    );
    vx.reopen();
    assert_eq!(vx.counts(), (2, 1), "no vector was written");
}

#[test]
fn a_multi_block_echo_needs_the_model_so_it_fails_with_model_not_downloaded_too() {
    // Every chunk has a vector, but the echo's chunk has two blocks, so the
    // best-block pick must embed them (req 13 and 16): embedding is needed.
    let mut vx = Vx::new();
    let open = vx.plain("Open Note", "The open passage.");
    let multi = vx.plain("Multi", "First block text.\n\nSecond block text.");
    vx.embed(&open, &e(0));
    vx.embed(&multi, &near(0, 1, 0.9));
    assert_eq!(vx.chunk_ids(&multi).len(), 1, "one chunk of two blocks");
    let path = vx.close();
    let hub = Tripwire::start();

    let (code, message) = c1_error(&run_echoes(&path, &open, &[], &hub));
    assert_eq!(code, "model_not_downloaded", "{message}");
    assert_eq!(hub.hits(), 0, "nothing contacted HF_ENDPOINT");
}

#[test]
fn a_cached_model_is_used_without_allow_download() {
    // A complete model in `model_cache_dir(<vault>)` counts as cached, so the
    // command loads it instead of refusing. The fake model bytes then fail
    // to load: embedder_unavailable, still with no network access.
    let (mut vx, open) = unembedded_vault();
    let path = vx.close();
    let cache = model_cache_dir(&path);
    write_fake_cached_model(&cache);
    assert!(
        FastEmbedder::is_cached(&cache),
        "the fake model reads cached"
    );
    let hub = Tripwire::start();

    let (code, message) = c1_error(&run_echoes(&path, &open, &[], &hub));
    assert_eq!(code, "embedder_unavailable", "{message}");
    assert_eq!(hub.hits(), 0, "a cached model loads with no network access");
}

// ---------------------------------------------------------------- AC 5

#[test]
fn nothing_to_embed_succeeds_with_no_model_cached_and_no_allow_download() {
    let (mut vx, open, cands) = many_candidates(2);
    let path = vx.close();
    let cache = model_cache_dir(&path);
    assert!(!FastEmbedder::is_cached(&cache), "no model is cached");
    let hub = Tripwire::start();

    let got = ok_json(&run_echoes(&path, &open, &[], &hub));
    assert_eq!(echo_ids(&got), cands, "{got}");
    assert_eq!(got["pending"], json!(0));
    assert_eq!(got["reason"], Value::Null);
    assert_eq!(hub.hits(), 0, "nothing contacted HF_ENDPOINT");
    assert!(!model_repo_dir(&cache).exists(), "no model was downloaded");
}

#[test]
fn allow_download_with_nothing_to_embed_still_never_downloads() {
    // The model is lazy (req 16): --allow-download only permits a download.
    let (mut vx, open, cands) = many_candidates(2);
    let path = vx.close();
    let hub = Tripwire::start();

    let got = ok_json(&run_echoes(&path, &open, &["--allow-download"], &hub));
    assert_eq!(echo_ids(&got), cands, "{got}");
    assert_eq!(hub.hits(), 0, "nothing contacted HF_ENDPOINT");
    assert!(!model_repo_dir(&model_cache_dir(&path)).exists());
}

// ---------------------------------------------------------------- AC 6

#[test]
fn allow_download_with_a_dead_hf_endpoint_fails_with_embedder_unavailable_and_the_cause() {
    let (mut vx, open) = unembedded_vault();
    let path = vx.close();
    let hub = Tripwire::start();

    let out = run_echoes(&path, &open, &["--allow-download"], &hub);
    let (code, message) = c1_error(&out);
    assert_eq!(code, "embedder_unavailable", "{message}");
    let cause = message
        .strip_prefix("embedder init failed: ")
        .unwrap_or_else(|| panic!("the model could not be loaded: {message}"));
    assert!(
        !cause.trim().is_empty(),
        "the cause is in the message: {message}"
    );
    assert!(
        hub.hits() > 0,
        "--allow-download tried to download from HF_ENDPOINT ({message})"
    );
    vx.reopen();
    assert_eq!(vx.counts(), (2, 1), "no vector was written");
}

// ---------------------------------------------------------------- AC 7 (D22)

fn golden(file: &str) -> String {
    let path = Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("tests/golden/help")
        .join(format!("{file}.txt"));
    fs::read_to_string(&path).unwrap_or_else(|e| panic!("{}: {e}", path.display()))
}

#[test]
fn echoes_help_matches_its_golden() {
    let hub = Tripwire::start();
    let got = ok_stdout(&memex(&["echoes", "--help"], &hub));
    let want = golden("echoes");
    assert_eq!(
        got, want,
        "memex echoes --help\n--- golden\n{want}--- got\n{got}"
    );
}

#[test]
fn top_level_help_lists_echoes_right_after_filing() {
    let hub = Tripwire::start();
    let help = ok_stdout(&memex(&["--help"], &hub));
    let rows: Vec<&str> = help
        .lines()
        .map(str::trim_start)
        .filter(|l| l.split_whitespace().next().is_some())
        .collect();
    let filing = rows
        .iter()
        .position(|l| l.starts_with("filing "))
        .unwrap_or_else(|| panic!("filing is listed: {help}"));
    let next = rows.get(filing + 1).copied().unwrap_or_default();
    assert!(
        next.starts_with("echoes "),
        "echoes is listed right after filing (D22): {help}"
    );
    let about = next.trim_start_matches("echoes").trim_start();
    assert_eq!(
        about,
        "Find passages in other, unlinked notes that are close to a note"
    );
}
