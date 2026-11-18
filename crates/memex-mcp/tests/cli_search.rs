//! WI #72 (Spec #59 requirements 34-36, architect D10, D11):
//! `memex search --vault <path> --query <text> [--limit <n>] [--allow-download]`.
//! Drives the real `memex` binary against temp vaults.
//!
//! - Success: exactly one compact JSON line on stdout, the value
//!   `memex_core::note_search::note_search` answers: `{"query", "semantic",
//!   "hits":[{note_id, note_title, note_role, day, chunk_id, snippet,
//!   start_byte, via, note_updated_at}], "truncated"}`. Exit 0.
//! - Failure: exit 1, nothing on stdout, one C1 JSON line on stderr.
//! - `--limit` takes 1-20 and defaults to 8 (`validate_limit`); out of range
//!   is `invalid_argument` with `invalid limit: <n> (1 to 20)`.
//! - Without `--allow-download` and no cached model: keyword hits,
//!   `semantic: "model_not_downloaded"`, no network access. With a cached
//!   model, or with `--allow-download` (which fetches it into
//!   `<vault>/.memex/models`), up to 64 chunks with no vector are embedded
//!   first and the answer is `semantic: "on"`. An embedder that cannot be
//!   fetched or loaded answers keyword hits as `"unavailable"`, exit 0.
//!
//! No test downloads or runs the real model. Every child runs with
//! `HF_HOME` (and any proxy) unset and `HF_ENDPOINT` pointed at a local
//! port: a [`fx::Tripwire`] that counts and drops connections, or a
//! [`FakeHub`] that serves a tiny stand-in model built here (an ONNX graph
//! of four nodes with 384-wide output and a word-level tokenizer) in the
//! layout hf-hub downloads. fastembed loads and runs it like the real one,
//! so the vector arm and pending-chunk embedding run for real.

#[path = "../../memex-core/tests/hf_cache_fixture/mod.rs"]
mod hf_cache_fixture;

use std::collections::BTreeSet;
use std::fs;
use std::io::{Read, Write};
use std::net::{TcpListener, TcpStream};
use std::path::{Path, PathBuf};
use std::process::{Command, Output, Stdio};
use std::sync::{Arc, Mutex};

use hf_cache_fixture as fx;
use memex_core::embedder::{Embedder, FastEmbedder};
use memex_core::indexer;
use memex_core::note_search::{note_search, SearchEmbedder};
use memex_core::notes::{create_note_as, CreateNote};
use memex_core::{Caller, Vault};
use memex_mcp::state::model_cache_dir;
use rusqlite::{params, Connection};
use serde_json::{json, Value};
use tempfile::TempDir;

/// The BGE-small-en-v1.5 vector width.
const DIM: usize = 384;
/// The CLI's `pending_cap` (echoes' `OTHERS_CAP`, Spec #59 requirement 35).
const CLI_OTHERS_CAP: usize = 64;
/// The day of the daily note in [`keyword_vault`].
const DAY: &str = "2026-09-05";
/// Body of the topic note: blank lines before its only block, so its chunk
/// starts past byte 0.
const TOPIC_BODY: &str = "\n\n\nThe jump arc needs coyote time.\n";
/// Proxy variables a child must not inherit: every hub here is local.
const PROXY_VARS: [&str; 6] = [
    "HTTP_PROXY",
    "HTTPS_PROXY",
    "ALL_PROXY",
    "http_proxy",
    "https_proxy",
    "all_proxy",
];

// ---------------------------------------------------------------- the stand-in model

fn varint(out: &mut Vec<u8>, mut v: u64) {
    loop {
        let b = (v & 0x7f) as u8;
        v >>= 7;
        if v == 0 {
            out.push(b);
            return;
        }
        out.push(b | 0x80);
    }
}

/// A varint field.
fn pb_int(out: &mut Vec<u8>, field: u64, v: u64) {
    varint(out, field << 3);
    varint(out, v);
}

/// A length-delimited field (bytes, string or message).
fn pb_bytes(out: &mut Vec<u8>, field: u64, data: &[u8]) {
    varint(out, (field << 3) | 2);
    varint(out, data.len() as u64);
    out.extend_from_slice(data);
}

/// One tensor dimension: a named (dynamic) one or a fixed size.
enum Dim {
    Param(&'static str),
    Value(u64),
}

/// `ValueInfoProto` for a tensor of ONNX element type `elem`.
fn value_info(name: &str, elem: u64, dims: &[Dim]) -> Vec<u8> {
    let mut shape = Vec::new();
    for d in dims {
        let mut dim = Vec::new();
        match d {
            Dim::Value(v) => pb_int(&mut dim, 1, *v),
            Dim::Param(p) => pb_bytes(&mut dim, 2, p.as_bytes()),
        }
        pb_bytes(&mut shape, 1, &dim);
    }
    let mut tensor = Vec::new();
    pb_int(&mut tensor, 1, elem);
    pb_bytes(&mut tensor, 2, &shape);
    let mut ty = Vec::new();
    pb_bytes(&mut ty, 1, &tensor);
    let mut vi = Vec::new();
    pb_bytes(&mut vi, 1, name.as_bytes());
    pb_bytes(&mut vi, 2, &ty);
    vi
}

/// An attribute: `ints` empty means an INT attribute with value `i`,
/// else an INTS attribute.
fn attribute(name: &str, i: u64, ints: &[u64]) -> Vec<u8> {
    let mut a = Vec::new();
    pb_bytes(&mut a, 1, name.as_bytes());
    if ints.is_empty() {
        pb_int(&mut a, 3, i);
        pb_int(&mut a, 20, 2);
    } else {
        for v in ints {
            pb_int(&mut a, 8, *v);
        }
        pb_int(&mut a, 20, 7);
    }
    a
}

fn node(op: &str, inputs: &[&str], output: &str, attrs: &[Vec<u8>]) -> Vec<u8> {
    let mut n = Vec::new();
    for i in inputs {
        pb_bytes(&mut n, 1, i.as_bytes());
    }
    pb_bytes(&mut n, 2, output.as_bytes());
    pb_bytes(&mut n, 3, format!("{op}_{output}").as_bytes());
    pb_bytes(&mut n, 4, op.as_bytes());
    for a in attrs {
        pb_bytes(&mut n, 5, a);
    }
    n
}

/// A 1-d FLOAT initializer.
fn float_tensor(name: &str, values: &[f32]) -> Vec<u8> {
    let mut t = Vec::new();
    pb_int(&mut t, 1, values.len() as u64);
    pb_int(&mut t, 2, 1);
    pb_bytes(&mut t, 8, name.as_bytes());
    let raw: Vec<u8> = values.iter().flat_map(|f| f.to_le_bytes()).collect();
    pb_bytes(&mut t, 9, &raw);
    t
}

/// An ONNX model (ir 8, opset 13) with BGE's inputs (`input_ids`,
/// `attention_mask`, INT64 `[batch, seq]`) and one FLOAT `[batch, 384]`
/// output: `max(input_ids) * W + B`. fastembed's CLS pooling takes a 2-d
/// output as is and normalizes each row, so every text gets a unit
/// 384-wide vector.
fn stand_in_onnx() -> Vec<u8> {
    const FLOAT: u64 = 1;
    const INT64: u64 = 7;
    let w: Vec<f32> = (0..DIM).map(|i| (i % 7) as f32 * 0.01).collect();
    let b: Vec<f32> = (0..DIM).map(|i| if i == 0 { 1.0 } else { 0.0 }).collect();
    let mut g = Vec::new();
    pb_bytes(
        &mut g,
        1,
        &node(
            "Cast",
            &["input_ids"],
            "ids_f",
            &[attribute("to", FLOAT, &[])],
        ),
    );
    pb_bytes(
        &mut g,
        1,
        &node(
            "ReduceMax",
            &["ids_f"],
            "ids_max",
            &[attribute("axes", 0, &[1]), attribute("keepdims", 1, &[])],
        ),
    );
    pb_bytes(&mut g, 1, &node("Mul", &["ids_max", "W"], "scaled", &[]));
    pb_bytes(&mut g, 1, &node("Add", &["scaled", "B"], "embedding", &[]));
    pb_bytes(&mut g, 2, b"stand_in");
    pb_bytes(&mut g, 5, &float_tensor("W", &w));
    pb_bytes(&mut g, 5, &float_tensor("B", &b));
    let seq = [Dim::Param("batch"), Dim::Param("seq")];
    pb_bytes(&mut g, 11, &value_info("input_ids", INT64, &seq));
    pb_bytes(&mut g, 11, &value_info("attention_mask", INT64, &seq));
    pb_bytes(
        &mut g,
        12,
        &value_info(
            "embedding",
            FLOAT,
            &[Dim::Param("batch"), Dim::Value(DIM as u64)],
        ),
    );
    let mut m = Vec::new();
    pb_int(&mut m, 1, 8);
    let mut opset = Vec::new();
    pb_int(&mut opset, 2, 13);
    pb_bytes(&mut m, 8, &opset);
    pb_bytes(&mut m, 7, &g);
    m
}

/// A word-level tokenizer: whitespace split, lowercase, `[CLS]` first, so
/// every text has at least one token.
fn stand_in_tokenizer() -> Vec<u8> {
    let words = [
        "[UNK]", "[PAD]", "[CLS]", "jump", "arc", "coyote", "time", "kites", "passage", "1",
    ];
    let vocab: serde_json::Map<String, Value> = words
        .iter()
        .enumerate()
        .map(|(i, w)| (w.to_string(), json!(i)))
        .collect();
    let tokenizer = json!({
        "version": "1.0",
        "truncation": null,
        "padding": null,
        "added_tokens": [],
        "normalizer": { "type": "Lowercase" },
        "pre_tokenizer": { "type": "Whitespace" },
        "post_processor": {
            "type": "TemplateProcessing",
            "single": [
                { "SpecialToken": { "id": "[CLS]", "type_id": 0 } },
                { "Sequence": { "id": "A", "type_id": 0 } }
            ],
            "pair": [
                { "SpecialToken": { "id": "[CLS]", "type_id": 0 } },
                { "Sequence": { "id": "A", "type_id": 0 } },
                { "Sequence": { "id": "B", "type_id": 1 } }
            ],
            "special_tokens": {
                "[CLS]": { "id": "[CLS]", "ids": [2], "tokens": ["[CLS]"] }
            }
        },
        "decoder": null,
        "model": { "type": "WordLevel", "vocab": vocab, "unk_token": "[UNK]" }
    });
    serde_json::to_vec(&tokenizer).unwrap()
}

/// The bytes of each file fastembed reads for BGE-small-en-v1.5
/// ([`fx::required_files`]), for the stand-in model.
fn stand_in_file(file: &str) -> Vec<u8> {
    match file {
        "tokenizer.json" => stand_in_tokenizer(),
        "config.json" => br#"{"pad_token_id": 1}"#.to_vec(),
        "special_tokens_map.json" => b"{}".to_vec(),
        "tokenizer_config.json" => br#"{"model_max_length": 512, "pad_token": "[PAD]"}"#.to_vec(),
        f if f.ends_with(".onnx") => stand_in_onnx(),
        other => panic!("fastembed reads a file the stand-in model lacks: {other}"),
    }
}

/// Writes the stand-in model into `cache_dir` as a finished hf-hub cache
/// (`refs/main` -> [`fx::COMMIT`], one plain file per required file).
fn write_cached_stand_in(cache_dir: &Path) {
    for f in fx::required_files() {
        let p = fx::snapshot_file(cache_dir, &f);
        fs::create_dir_all(p.parent().unwrap()).unwrap();
        fs::write(&p, stand_in_file(&f)).unwrap();
    }
    fx::write_ref(cache_dir, fx::COMMIT);
}

// ---------------------------------------------------------------- the fake hub

/// A local Hugging Face hub that serves the stand-in model the way hf-hub
/// 0.5 fetches a file: `GET /<repo>/resolve/main/<file>` with a `Range`
/// header, answered 206 with `etag`, `x-repo-commit` and `Content-Range`.
/// Records each request path.
struct FakeHub {
    url: String,
    requests: Arc<Mutex<Vec<String>>>,
}

impl FakeHub {
    fn start() -> Self {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let url = format!("http://{}", listener.local_addr().unwrap());
        let requests = Arc::new(Mutex::new(Vec::new()));
        let seen = requests.clone();
        std::thread::spawn(move || {
            for s in listener.incoming().flatten() {
                let seen = seen.clone();
                std::thread::spawn(move || serve(s, &seen));
            }
        });
        Self { url, requests }
    }

    fn requests(&self) -> Vec<String> {
        self.requests.lock().unwrap().clone()
    }
}

/// The request head: everything up to the blank line.
fn read_head(s: &mut TcpStream) -> Option<String> {
    let mut head = Vec::new();
    let mut byte = [0u8; 1];
    while !head.ends_with(b"\r\n\r\n") {
        if s.read(&mut byte).ok()? == 0 {
            return None;
        }
        head.push(byte[0]);
    }
    String::from_utf8(head).ok()
}

fn serve(mut s: TcpStream, seen: &Mutex<Vec<String>>) {
    let Some(head) = read_head(&mut s) else {
        return;
    };
    let mut lines = head.lines();
    let path = lines
        .next()
        .and_then(|l| l.split_whitespace().nth(1))
        .unwrap_or_default()
        .to_string();
    let range_start: usize = lines
        .find_map(|l| {
            let (k, v) = l.split_once(':')?;
            k.trim().eq_ignore_ascii_case("range").then(|| v.trim())
        })
        .and_then(|v| v.strip_prefix("bytes="))
        .and_then(|v| v.split('-').next())
        .and_then(|v| v.parse().ok())
        .unwrap_or(0);
    seen.lock().unwrap().push(path.clone());
    let prefix = format!("/{}/resolve/main/", fx::model_code());
    let file = path.strip_prefix(&prefix).map(str::to_string);
    let body = file
        .as_deref()
        .filter(|f| fx::required_files().iter().any(|r| r == f))
        .map(stand_in_file);
    let response = match (file, body) {
        (Some(file), Some(body)) if range_start < body.len() => {
            // `bytes=0-0` (the metadata probe) gets one byte; `bytes=N-` the rest.
            let end = if head.contains("bytes=0-0") {
                0
            } else {
                body.len() - 1
            };
            let part = &body[range_start..=end];
            let mut r = format!(
                "HTTP/1.1 206 Partial Content\r\n\
                 etag: \"{}\"\r\n\
                 x-repo-commit: {}\r\n\
                 Content-Range: bytes {range_start}-{end}/{}\r\n\
                 Content-Length: {}\r\n\
                 Connection: close\r\n\r\n",
                fx::etag_for(&file),
                fx::COMMIT,
                body.len(),
                part.len()
            )
            .into_bytes();
            r.extend_from_slice(part);
            r
        }
        _ => b"HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".to_vec(),
    };
    let _ = s.write_all(&response);
    let _ = s.flush();
}

// ---------------------------------------------------------------- the binary

/// `memex <args…>` with `HF_ENDPOINT` at `hub`, `HF_HOME` and proxies unset.
fn memex(args: &[&str], hub: &str) -> Output {
    let mut cmd = Command::new(env!("CARGO_BIN_EXE_memex"));
    cmd.args(args)
        .env("HF_ENDPOINT", hub)
        .env_remove("HF_HOME")
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    for v in PROXY_VARS {
        cmd.env_remove(v);
    }
    cmd.output().expect("run memex")
}

/// `memex search --vault <vault> --query <query> <extra…>`.
fn run_search(vault: &Path, query: &str, extra: &[&str], hub: &str) -> Output {
    let mut args = vec![
        "search",
        "--vault",
        vault.to_str().unwrap(),
        "--query",
        query,
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
    assert!(out.status.success(), "expected success; {}", describe(out));
    assert!(
        out.stderr.is_empty(),
        "stderr must be empty on success; {}",
        describe(out)
    );
    String::from_utf8(out.stdout.clone()).expect("utf8 stdout")
}

/// Exactly one compact JSON object on one stdout line.
fn ok_json(out: &Output) -> Value {
    let stdout = ok_stdout(out);
    let line = stdout
        .strip_suffix('\n')
        .unwrap_or_else(|| panic!("stdout ends with one newline: {stdout:?}"));
    assert!(
        !line.is_empty() && !line.contains('\n'),
        "stdout must be one line: {stdout:?}"
    );
    let v: Value =
        serde_json::from_str(line).unwrap_or_else(|e| panic!("stdout not JSON ({e}): {stdout}"));
    assert!(v.is_object(), "a bare JSON object: {v}");
    assert_eq!(
        line,
        serde_json::to_string(&v).unwrap(),
        "the line is compact JSON"
    );
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

    /// Creates a note as the person and indexes it with no embedder, so its
    /// chunks have no vector.
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

    fn chunk_start(&self, note: &str) -> Option<i64> {
        self.conn()
            .query_row(
                "SELECT start_byte FROM chunks WHERE note_id = ? ORDER BY ord LIMIT 1",
                params![note],
                |r| r.get(0),
            )
            .unwrap()
    }

    /// `(chunks, chunks with a vector)`; 0 vectors while `chunk_vec` does
    /// not exist.
    fn counts(&self) -> (i64, i64) {
        let chunks: i64 = self
            .conn()
            .query_row("SELECT COUNT(*) FROM chunks", [], |r| r.get(0))
            .unwrap();
        let has_vec: bool = self
            .conn()
            .query_row(
                "SELECT COUNT(*) > 0 FROM sqlite_master WHERE name = 'chunk_vec'",
                [],
                |r| r.get(0),
            )
            .unwrap();
        let embedded = if has_vec {
            self.conn()
                .query_row(
                    "SELECT COUNT(*) FROM chunk_vec v JOIN chunks c ON c.id = v.chunk_id",
                    [],
                    |r| r.get(0),
                )
                .unwrap()
        } else {
            0
        };
        (chunks, embedded)
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

/// A vault where the word "jump" is in a daily, a topic and a plain note,
/// and not in a fourth note. Every chunk is pending (no vector).
struct Keyword {
    vx: Vx,
    daily: String,
    topic: String,
    plain: String,
}

fn keyword_vault() -> Keyword {
    let mut vx = Vx::new();
    let daily = vx.create(
        DAY,
        "Fixed the jump arc.\n",
        Some(json!({ "role": "daily" })),
    );
    let topic = vx.create("Physics", TOPIC_BODY, Some(json!({ "role": "topic" })));
    let plain = vx.create("Plain", "A plain jump note.\n", None);
    vx.create("Far", "Nothing like it at all.\n", None);
    Keyword {
        vx,
        daily,
        topic,
        plain,
    }
}

/// A vault with `n` single-chunk notes that all match "kites", none
/// embedded.
fn kites_vault(n: usize) -> Vx {
    let mut vx = Vx::new();
    for i in 0..n {
        vx.create(
            &format!("Kite note {i:03}"),
            &format!("Passage {i} about kites.\n"),
            None,
        );
    }
    assert_eq!(
        vx.counts(),
        (n as i64, 0),
        "{n} single-chunk notes, none embedded"
    );
    vx
}

/// What core `note_search` answers on the (closed) vault at `path` with no
/// embedder (`NotDownloaded`), as JSON.
fn core_keyword(path: &Path, query: &str, limit: usize) -> Value {
    let mut vault = Vault::open(path).unwrap();
    let mut conn: &mut Connection = vault.connection_mut();
    let got = note_search(
        &mut conn,
        query,
        limit,
        SearchEmbedder::NotDownloaded,
        CLI_OTHERS_CAP,
    )
    .unwrap_or_else(|e| panic!("core note_search {query:?}: {e}"));
    serde_json::to_value(got).unwrap()
}

fn note_ids(v: &Value) -> BTreeSet<String> {
    v["hits"]
        .as_array()
        .unwrap_or_else(|| panic!("hits is an array: {v}"))
        .iter()
        .map(|h| h["note_id"].as_str().expect("note_id").to_string())
        .collect()
}

fn hit_of<'a>(v: &'a Value, note: &str) -> &'a Value {
    v["hits"]
        .as_array()
        .unwrap()
        .iter()
        .find(|h| h["note_id"] == json!(note))
        .unwrap_or_else(|| panic!("a hit for {note}: {v}"))
}

fn keys(v: &Value) -> BTreeSet<&str> {
    v.as_object()
        .unwrap_or_else(|| panic!("an object: {v}"))
        .keys()
        .map(String::as_str)
        .collect()
}

fn is_iso_date(v: &Value) -> bool {
    v.as_str().is_some_and(|s| {
        let b = s.as_bytes();
        b.len() == 10
            && b[4] == b'-'
            && b[7] == b'-'
            && b.iter()
                .enumerate()
                .all(|(i, c)| i == 4 || i == 7 || c.is_ascii_digit())
    })
}

/// Requirement 34's key set and value types, hit by hit.
fn assert_requirement_34_shape(v: &Value) {
    assert_eq!(
        keys(v),
        BTreeSet::from(["query", "semantic", "hits", "truncated"]),
        "{v}"
    );
    assert!(v["query"].is_string(), "query: {v}");
    let semantic = v["semantic"].as_str().unwrap_or_default();
    assert!(
        ["on", "model_not_downloaded", "unavailable"].contains(&semantic),
        "the CLI answers on, model_not_downloaded or unavailable: {v}"
    );
    assert!(v["truncated"].is_boolean(), "truncated: {v}");
    let hits = v["hits"].as_array().expect("hits is an array");
    for h in hits {
        assert_eq!(
            keys(h),
            BTreeSet::from([
                "note_id",
                "note_title",
                "note_role",
                "day",
                "chunk_id",
                "snippet",
                "start_byte",
                "via",
                "note_updated_at",
            ]),
            "{h}"
        );
        for k in ["note_id", "note_title", "chunk_id", "snippet"] {
            assert!(h[k].is_string(), "{k} is a string: {h}");
        }
        assert!(
            h["note_role"].is_null() || h["note_role"] == "daily" || h["note_role"] == "topic",
            "note_role: {h}"
        );
        assert!(h["day"].is_null() || is_iso_date(&h["day"]), "day: {h}");
        assert!(h["via"].is_null() || is_iso_date(&h["via"]), "via: {h}");
        assert!(
            h["start_byte"].is_null() || h["start_byte"].is_u64(),
            "start_byte: {h}"
        );
        assert!(h["note_updated_at"].is_i64(), "note_updated_at: {h}");
    }
}

fn model_repo_dir(vault: &Path) -> PathBuf {
    fx::repo_dir(&model_cache_dir(vault))
}

// ---------------------------------------------------------------- fixture sanity

#[test]
fn the_stand_in_model_loads_and_embeds_in_process() {
    // The CLI tests below rely on fastembed loading this stand-in model as
    // it loads BGE-small; pin that against the real fastembed and ORT.
    if std::env::var_os("HF_HOME").is_some() {
        eprintln!("skipped: HF_HOME is set, so fastembed would not read the temp cache");
        return;
    }
    let dir = tempfile::tempdir().unwrap();
    let cache = dir.path().join("models");
    write_cached_stand_in(&cache);
    assert!(FastEmbedder::is_cached(&cache), "the stand-in reads cached");
    let e = FastEmbedder::bge_small_en_v15(Some(cache));
    let got = e
        .embed_batch(&["the jump arc".to_string(), "kites".to_string()])
        .unwrap_or_else(|err| panic!("the stand-in model embeds: {err}"));
    assert_eq!(got.len(), 2);
    for v in &got {
        assert_eq!(v.len(), DIM);
        let norm: f32 = v.iter().map(|x| x * x).sum::<f32>().sqrt();
        assert!((norm - 1.0).abs() < 1e-3, "unit vector, norm {norm}");
    }
}

// ---------------------------------------------------------------- AC 1

#[test]
fn search_prints_one_compact_json_line_in_the_requirement_34_shape_and_exits_0() {
    let mut fx_vault = keyword_vault();
    let topic_start = fx_vault.vx.chunk_start(&fx_vault.topic);
    let path = fx_vault.vx.close();
    let hub = fx::Tripwire::start();

    let got = ok_json(&run_search(&path, "jump", &[], &hub.url));
    assert_requirement_34_shape(&got);
    assert_eq!(got["query"], json!("jump"));
    assert_eq!(
        note_ids(&got),
        BTreeSet::from([
            fx_vault.daily.clone(),
            fx_vault.topic.clone(),
            fx_vault.plain.clone()
        ]),
        "every note with the word, and no other: {got}"
    );

    let daily = hit_of(&got, &fx_vault.daily);
    assert_eq!(daily["note_role"], json!("daily"));
    assert_eq!(daily["day"], json!(DAY));
    assert_eq!(daily["note_title"], json!(DAY));
    let topic = hit_of(&got, &fx_vault.topic);
    assert_eq!(topic["note_role"], json!("topic"));
    assert_eq!(topic["day"], Value::Null);
    assert_eq!(topic["start_byte"], json!(topic_start), "{topic}");
    assert!(
        topic_start.unwrap_or(0) > 0,
        "the topic chunk starts past 0"
    );
    let plain = hit_of(&got, &fx_vault.plain);
    assert_eq!(plain["note_role"], Value::Null);
    assert_eq!(plain["day"], Value::Null);
    assert_eq!(got["truncated"], json!(false));

    assert_eq!(
        got,
        core_keyword(&path, "jump", 8),
        "the line is core note_search's answer"
    );
}

#[test]
fn without_limit_at_most_eight_hits_are_printed_and_truncated_is_set() {
    let mut vx = kites_vault(10);
    let path = vx.close();
    let hub = fx::Tripwire::start();

    let got = ok_json(&run_search(&path, "kites", &[], &hub.url));
    assert_eq!(got["hits"].as_array().unwrap().len(), 8, "{got}");
    assert_eq!(got["truncated"], json!(true), "{got}");
}

// ---------------------------------------------------------------- AC 2

#[test]
fn without_a_cached_model_and_without_allow_download_it_answers_keyword_hits_as_model_not_downloaded(
) {
    let mut fx_vault = keyword_vault();
    let before = fx_vault.vx.counts();
    let path = fx_vault.vx.close();
    assert!(!FastEmbedder::is_cached(&model_cache_dir(&path)));
    let hub = fx::Tripwire::start();

    let out = run_search(&path, "jump", &[], &hub.url);
    let got = ok_json(&out);
    assert_eq!(got["semantic"], json!("model_not_downloaded"), "{got}");
    assert_eq!(
        note_ids(&got),
        BTreeSet::from([fx_vault.daily, fx_vault.topic, fx_vault.plain]),
        "keyword hits: {got}"
    );
    assert_eq!(hub.hits(), 0, "nothing contacted HF_ENDPOINT");
    assert!(!model_repo_dir(&path).exists(), "no model was downloaded");
    fx_vault.vx.reopen();
    assert_eq!(fx_vault.vx.counts(), before, "no chunk was embedded");
}

// ---------------------------------------------------------------- AC 3

#[test]
fn allow_download_fetches_the_model_from_the_hub_into_the_vault_models_folder_and_answers_on() {
    let mut fx_vault = keyword_vault();
    let (chunks, _) = fx_vault.vx.counts();
    let path = fx_vault.vx.close();
    assert!(!model_repo_dir(&path).exists());
    let hub = FakeHub::start();

    let got = ok_json(&run_search(&path, "jump", &["--allow-download"], &hub.url));
    assert_requirement_34_shape(&got);
    assert_eq!(got["semantic"], json!("on"), "{got}");
    let ids = note_ids(&got);
    for n in [&fx_vault.daily, &fx_vault.topic, &fx_vault.plain] {
        assert!(ids.contains(n), "keyword hit {n} kept: {got}");
    }

    let cache = model_cache_dir(&path);
    let requests = hub.requests();
    for f in fx::required_files() {
        assert!(
            requests.iter().any(|r| r.ends_with(&format!("/{f}"))),
            "{f} was fetched from HF_ENDPOINT: {requests:?}"
        );
        let cached = fx::snapshot_file(&cache, &f);
        assert_eq!(
            fs::read(&cached).unwrap_or_else(|e| panic!("{}: {e}", cached.display())),
            stand_in_file(&f),
            "{f} is in <vault>/.memex/models"
        );
    }
    assert!(
        FastEmbedder::is_cached(&cache),
        "the model now reads cached"
    );

    fx_vault.vx.reopen();
    assert_eq!(
        fx_vault.vx.counts(),
        (chunks, chunks),
        "the pending chunks got vectors"
    );
}

#[test]
fn after_a_download_a_run_without_allow_download_answers_on_with_no_network_access() {
    let mut fx_vault = keyword_vault();
    let path = fx_vault.vx.close();
    let hub = FakeHub::start();
    let first = ok_json(&run_search(&path, "jump", &["--allow-download"], &hub.url));
    assert_eq!(first["semantic"], json!("on"), "{first}");

    let dead = fx::Tripwire::start();
    let got = ok_json(&run_search(&path, "jump", &[], &dead.url));
    assert_eq!(got["semantic"], json!("on"), "{got}");
    assert_eq!(dead.hits(), 0, "the cached model loads offline");
}

// ---------------------------------------------------------------- AC 4

#[test]
fn allow_download_with_an_unreachable_hub_answers_keyword_hits_as_unavailable_and_exits_0() {
    let mut fx_vault = keyword_vault();
    let path = fx_vault.vx.close();
    let hub = fx::Tripwire::start();

    let got = ok_json(&run_search(&path, "jump", &["--allow-download"], &hub.url));
    assert_eq!(got["semantic"], json!("unavailable"), "{got}");
    assert!(hub.hits() > 0, "--allow-download tried HF_ENDPOINT");
    let keyword = core_keyword(&path, "jump", 8);
    assert_eq!(got["hits"], keyword["hits"], "keyword hits only");
    assert_eq!(got["truncated"], keyword["truncated"]);
    fx_vault.vx.reopen();
    assert_eq!(fx_vault.vx.counts().1, 0, "no vector was written");
}

#[test]
fn a_cached_model_that_cannot_load_answers_keyword_hits_as_unavailable_and_exits_0() {
    // Spec #59 requirement 35: an embedder that fails to load is keyword
    // only, never a C1 failure (echoes answers embedder_unavailable here).
    let mut fx_vault = keyword_vault();
    let path = fx_vault.vx.close();
    let cache = model_cache_dir(&path);
    fx::write_complete(&cache);
    assert!(
        FastEmbedder::is_cached(&cache),
        "the broken model reads cached"
    );
    let hub = fx::Tripwire::start();

    let got = ok_json(&run_search(&path, "jump", &[], &hub.url));
    assert_eq!(got["semantic"], json!("unavailable"), "{got}");
    assert_eq!(got["hits"], core_keyword(&path, "jump", 8)["hits"]);
    assert_eq!(hub.hits(), 0, "a cached model loads with no network access");
}

// ---------------------------------------------------------------- AC 5

#[test]
fn a_query_of_minus_one_is_searched_for_and_is_not_a_usage_error() {
    let mut vx = Vx::new();
    vx.create("Scores", "The score was -1 today.\n", None);
    let path = vx.close();
    let hub = fx::Tripwire::start();

    let out = run_search(&path, "-1", &[], &hub.url);
    assert_ne!(
        out.status.code(),
        Some(2),
        "not a clap usage error; {}",
        describe(&out)
    );
    let got = ok_json(&out);
    assert_eq!(got["query"], json!("-1"), "{got}");
    assert_eq!(got, core_keyword(&path, "-1", 8));
}

// ---------------------------------------------------------------- AC 6

#[test]
fn limit_0_and_limit_21_exit_1_with_invalid_argument_on_stderr() {
    let mut fx_vault = keyword_vault();
    let path = fx_vault.vx.close();
    let hub = fx::Tripwire::start();
    for n in ["0", "21"] {
        let (code, message) = c1_error(&run_search(&path, "jump", &["--limit", n], &hub.url));
        assert_eq!(code, "invalid_argument", "--limit {n}: {message}");
        assert_eq!(message, format!("invalid limit: {n} (1 to 20)"));
    }
}

#[test]
fn limit_1_and_limit_20_are_accepted_and_cap_the_hits() {
    let mut vx = kites_vault(25);
    let path = vx.close();
    let hub = fx::Tripwire::start();
    for (n, want) in [("1", 1), ("20", 20)] {
        let got = ok_json(&run_search(&path, "kites", &["--limit", n], &hub.url));
        assert_eq!(
            got["hits"].as_array().unwrap().len(),
            want,
            "--limit {n}: {got}"
        );
        assert_eq!(got["truncated"], json!(true), "--limit {n}: {got}");
    }
}

// ---------------------------------------------------------------- AC 7

#[test]
fn an_empty_query_answers_no_hits_and_exits_0() {
    let mut fx_vault = keyword_vault();
    let path = fx_vault.vx.close();
    let hub = fx::Tripwire::start();
    for q in ["", "   "] {
        let got = ok_json(&run_search(&path, q, &[], &hub.url));
        assert_eq!(got["hits"], json!([]), "{q:?}: {got}");
        assert_eq!(got["truncated"], json!(false), "{q:?}: {got}");
        assert_eq!(got["query"], json!(q), "the query is echoed as given");
    }
}

// ---------------------------------------------------------------- AC 8

#[test]
fn a_vault_path_that_does_not_exist_exits_1_with_c1_json_on_stderr() {
    let dir = tempfile::tempdir().unwrap();
    let missing = dir.path().join("no-such-vault");
    let hub = fx::Tripwire::start();

    let (code, message) = c1_error(&run_search(&missing, "jump", &[], &hub.url));
    assert!(!code.is_empty(), "a C1 code");
    assert!(!message.is_empty(), "a C1 message");
}

#[test]
fn allow_download_with_a_missing_vault_path_creates_nothing_and_contacts_no_hub() {
    let dir = tempfile::tempdir().unwrap();
    let missing = dir.path().join("no-such-vault");
    let hub = fx::Tripwire::start();

    c1_error(&run_search(
        &missing,
        "jump",
        &["--allow-download"],
        &hub.url,
    ));
    assert!(
        !missing.exists(),
        "no folder is made at a missing vault path"
    );
    assert_eq!(hub.hits(), 0, "nothing contacted HF_ENDPOINT");
}

// ---------------------------------------------------------------- AC 9

#[test]
fn with_a_cached_model_one_run_embeds_at_most_others_cap_chunks_that_had_no_vector() {
    let mut vx = kites_vault(CLI_OTHERS_CAP + 6);
    let path = vx.close();
    write_cached_stand_in(&model_cache_dir(&path));
    let hub = fx::Tripwire::start();

    let got = ok_json(&run_search(&path, "kites", &[], &hub.url));
    assert_eq!(got["semantic"], json!("on"), "{got}");
    vx.reopen();
    assert_eq!(
        vx.counts(),
        ((CLI_OTHERS_CAP + 6) as i64, CLI_OTHERS_CAP as i64),
        "one run embeds 64 pending chunks"
    );
    vx.close();

    ok_json(&run_search(&path, "kites", &[], &hub.url));
    vx.reopen();
    assert_eq!(
        vx.counts(),
        ((CLI_OTHERS_CAP + 6) as i64, (CLI_OTHERS_CAP + 6) as i64),
        "the next run embeds the rest"
    );
    assert_eq!(
        hub.hits(),
        0,
        "the cached model loads with no network access"
    );
}

// ---------------------------------------------------------------- AC 10

#[test]
fn top_level_help_lists_search() {
    let hub = fx::Tripwire::start();
    let help = ok_stdout(&memex(&["--help"], &hub.url));
    let rows: Vec<&str> = help
        .lines()
        .map(str::trim_start)
        .filter(|l| l.split_whitespace().next() == Some("search"))
        .collect();
    assert_eq!(rows.len(), 1, "search is listed once: {help}");
    let about = rows[0].trim_start_matches("search").trim();
    assert!(!about.is_empty(), "search has an about line: {help}");
    assert!(
        !about.to_lowercase().contains("snippet"),
        "GLOSSARY avoid term: {about}"
    );
}

#[test]
fn search_help_names_its_options_and_avoids_the_glossary_term_snippet() {
    let hub = fx::Tripwire::start();
    let help = ok_stdout(&memex(&["search", "--help"], &hub.url));
    for opt in ["--vault", "--query", "--limit", "--allow-download"] {
        assert!(
            help.contains(opt),
            "memex search --help names {opt}: {help}"
        );
    }
    assert!(
        help.contains("[default: 8]"),
        "--limit defaults to 8: {help}"
    );
    assert!(
        !help.to_lowercase().contains("snippet"),
        "GLOSSARY avoid term in help text: {help}"
    );
}
