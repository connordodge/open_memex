//! WI #137 (Spec #123 R43, R46-R48, ruling D18, released-client compat):
//! the search JSON of `memex search`, the MCP `search` tool and
//! `GET /vaults/{name}/api/v1/search` over attachments, and the
//! `/embeddings` counts.
//!
//! - A passage hit that came from an attachment carries `attachment: {name,
//!   path}`; the results carry a top-level `attachments` list of `{name,
//!   path, type, size, snippet?, notes: [{id, title}]}`. Each new field is
//!   present only when it has a value, never `null`, and every hit keeps
//!   v0.6.0's required `chunk_id`, `snippet` and `note_updated_at`
//!   (`app/lib/src/vault_access/search_access.dart`). A body with no
//!   attachment match has exactly the v0.6 keys.
//! - `app/test/fixtures/api_v1/search/attachments.json` (D18, read by the
//!   palette's Attachments group, #148) is the full router's answer to
//!   `?q=heron&limit=8` on [`build_vault`]'s vault. It is compared after
//!   `normalize_volatile` (minted ids and timestamps), and rewritten under
//!   `MEMEX_BLESS=1` with the raw answer, so the app reads real ids and
//!   integer timestamps. It is not an `index.json` row.
//!
//! The V9 attachment tables are seeded directly (no extraction, #136). Every
//! server is the full `server::router()`. No real model, no network: the CLI
//! runs with `HF_ENDPOINT` at a closed port and `HF_HOME` unset.

#[path = "support/api_fixtures.rs"]
mod api_fixtures;
#[path = "support/server.rs"]
mod server;

use std::collections::BTreeSet;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::Arc;
use std::time::Duration;

use memex_core::attachments;
use memex_core::indexer;
use memex_core::notes::{create_note_as, CreateNote, Note};
use memex_core::schema;
use memex_core::{Caller, Vault};
use memex_mcp::state::AppState;
use memex_mcp::tools::{Memex, SearchParams};
use rmcp::handler::server::wrapper::Parameters;
use rusqlite::{params, Connection};
use serde_json::{json, Value};

use api_fixtures::{api_v1_dir, bless_requested, canonical_json, normalize_volatile};
use server::{client, Reply, TestServer, TEST_TOKEN};

/// The vault folder under the served root.
const VAULT: &str = "v";
const DAY: &str = "2026-10-20";
/// The block id the topic transcludes (the day's attachment line).
const DAY_BLOCK: &str = "sk3tch";
const QUERY: &str = "heron";
/// Matches only Alpha Walk's own text: no attachment.
const PLAIN_QUERY: &str = "dawn";
const LIMIT: usize = 8;
const FIXTURE: &str = "attachments.json";
const FIELD_TEXT: &str = "The heron waited by the mill race until dusk.";

/// The legacy `note_search` hit keys (v0.6.0 reads these).
const NOTE_HIT_KEYS: [&str; 9] = [
    "chunk_id",
    "day",
    "note_id",
    "note_role",
    "note_title",
    "note_updated_at",
    "snippet",
    "start_byte",
    "via",
];

// ---------------------------------------------------------------- the vault

/// One seeded attachment.
struct Att {
    name: &'static str,
    path: String,
    markdown: String,
}

/// Seeds the V9 index rows of attachment `name` (hash `h2…`): its
/// `attachments` row and one chunk per text.
fn seed_attachment(
    conn: &Connection,
    h2: &str,
    name: &'static str,
    size: i64,
    chunks: &[&str],
) -> Att {
    let hash = h2.repeat(32);
    let markdown = attachments::markdown_for(name, &hash);
    let path = attachments::parse_reference(&markdown)
        .expect("fixture: an R4 reference")
        .target
        .path;
    let state = if chunks.is_empty() { "empty" } else { "done" };
    conn.execute(
        "INSERT INTO attachments (path, name, type, size, extract_state, extract_error, extracted_at)
         VALUES (?, ?, ?, ?, ?, NULL, 1790000000000)",
        params![path, name, attachments::mime_for(name), size, state],
    )
    .expect("attachments exists (schema V9)");
    for (ord, text) in chunks.iter().enumerate() {
        let id = format!("att-{h2}-{ord}");
        conn.execute(
            "INSERT INTO attachment_chunks (id, path, ord, content, token_count, embed_model_version)
             VALUES (?, ?, ?, ?, ?, NULL)",
            params![id, path, ord as i64, text, text.split_whitespace().count() as i64],
        )
        .unwrap();
        conn.execute(
            "INSERT INTO attachment_chunk_fts (content, chunk_id, path) VALUES (?, ?, ?)",
            params![text, id, path],
        )
        .unwrap();
    }
    Att {
        name,
        path,
        markdown,
    }
}

fn create(vault: &mut Vault, title: &str, body: &str, fm: Option<Value>) -> Note {
    // Ids are ULIDs: a new millisecond per note keeps id order = creation
    // order = title order below, so ties sort the same on every run.
    std::thread::sleep(Duration::from_millis(2));
    let note = create_note_as(
        vault,
        CreateNote {
            title: Some(title.into()),
            content_md: body.into(),
            frontmatter: fm,
        },
        Caller::Person,
    )
    .unwrap_or_else(|e| panic!("create {title}: {e}"));
    let stored: String = vault
        .connection_ref()
        .query_row(
            "SELECT content_md FROM notes WHERE id = ?",
            [note.id.as_str()],
            |r| r.get(0),
        )
        .unwrap();
    indexer::reindex_note(vault.connection_mut(), note.id.as_str(), &stored, None)
        .unwrap_or_else(|e| panic!("reindex {title}: {e}"));
    note
}

/// What [`build_vault`] made.
struct Built {
    vault_dir: PathBuf,
    field: Att,
    sketch: Att,
    day: Note,
    alpha: Note,
    bay: Note,
    topic: Note,
}

/// The D18 vault at `<root>/v`, closed on return. For [`QUERY`]:
///
/// - `Field Notes.txt` matches by content and is referenced by Bay, Cove,
///   Dune and Fen (four notes: the palette's `+N`);
/// - `Heron Sketch.png` (no text) matches by name and is referenced by the
///   daily note 2026-10-20, whose attachment line Bird Topics transcludes (a
///   hit with `via`);
/// - Alpha Walk matches by its own text only (a hit without `attachment`).
fn build_vault(root: &Path) -> Built {
    let vault_dir = root.join(VAULT);
    let mut vault = Vault::create(&vault_dir).unwrap();
    let conn = vault.connection_ref();
    let field = seed_attachment(conn, "f1", "Field Notes.txt", 2048, &[FIELD_TEXT]);
    let sketch = seed_attachment(conn, "a5", "Heron Sketch.png", 81234, &[]);

    let day = create(
        &mut vault,
        DAY,
        &format!("Pond morning.\n\n{}\n\nRain later.\n", sketch.markdown),
        Some(json!({ "role": "daily" })),
    );
    let pinned = vault
        .connection_ref()
        .execute(
            "UPDATE blocks SET block_id = ? WHERE note_id = ? AND ord = 1",
            params![DAY_BLOCK, day.id.as_str()],
        )
        .unwrap();
    assert_eq!(
        pinned, 1,
        "fixture: the day's second block is the sketch line"
    );
    let alpha = create(&mut vault, "Alpha Walk", "Saw a heron at dawn.", None);
    let bay = create(
        &mut vault,
        "Bay",
        &format!("Bay trip.\n\n{}\n", field.markdown),
        None,
    );
    let topic = create(
        &mut vault,
        "Bird Topics",
        &format!("Birds.\n\n![[{DAY}#^{DAY_BLOCK}]]\n"),
        Some(json!({ "role": "topic" })),
    );
    for title in ["Cove", "Dune", "Fen"] {
        create(
            &mut vault,
            title,
            &format!("{title} trip.\n\n{}\n", field.markdown),
            None,
        );
    }
    create(&mut vault, "Quiet", "Nothing to see here.", None);
    drop(vault);
    Built {
        vault_dir,
        field,
        sketch,
        day,
        alpha,
        bay,
        topic,
    }
}

// ---------------------------------------------------------------- JSON checks

fn keys(v: &Value) -> BTreeSet<String> {
    v.as_object()
        .unwrap_or_else(|| panic!("not an object: {v}"))
        .keys()
        .cloned()
        .collect()
}

fn key_set(ks: &[&str]) -> BTreeSet<String> {
    ks.iter().map(|k| k.to_string()).collect()
}

/// Every `attachment`, `attachments` and `snippet` value anywhere in `v`
/// that is `null` (new fields are omitted, never `null`).
fn null_new_fields(v: &Value, at: &str, out: &mut Vec<String>) {
    match v {
        Value::Object(m) => {
            for (k, x) in m {
                let here = format!("{at}.{k}");
                if matches!(k.as_str(), "attachment" | "attachments" | "snippet") && x.is_null() {
                    out.push(here.clone());
                }
                null_new_fields(x, &here, out);
            }
        }
        Value::Array(a) => {
            for (i, x) in a.iter().enumerate() {
                null_new_fields(x, &format!("{at}[{i}]"), out);
            }
        }
        _ => {}
    }
}

fn assert_no_null_new_fields(v: &Value, what: &str) {
    let mut out = Vec::new();
    null_new_fields(v, "", &mut out);
    assert!(out.is_empty(), "{what}: null new fields at {out:?}");
}

fn hit_on<'a>(hits: &'a [Value], note: &Note) -> &'a Value {
    let on: Vec<&Value> = hits
        .iter()
        .filter(|h| h["note_id"] == json!(note.id.as_str()))
        .collect();
    assert_eq!(on.len(), 1, "one hit on {}: {hits:#?}", note.title);
    on[0]
}

fn entry<'a>(list: &'a Value, att: &Att) -> &'a Value {
    list.as_array()
        .unwrap_or_else(|| panic!("attachments is an array: {list}"))
        .iter()
        .find(|a| a["path"] == json!(att.path))
        .unwrap_or_else(|| panic!("{} is listed: {list:#}", att.name))
}

/// The attachment fields of a [`QUERY`] answer (`hits_key` is `hits`, or
/// `results` for the MCP tool), checked on every surface alike.
fn assert_attachment_answer(v: &Value, hits_key: &str, b: &Built, what: &str) {
    assert_no_null_new_fields(v, what);
    let hits = v[hits_key]
        .as_array()
        .unwrap_or_else(|| panic!("{what}: no {hits_key} array: {v}"));
    for h in hits {
        assert!(h["chunk_id"].is_string(), "{what}: chunk_id on {h}");
        assert!(h["snippet"].is_string(), "{what}: snippet on {h}");
        if hits_key == "hits" {
            assert!(
                h["note_updated_at"].is_i64(),
                "{what}: note_updated_at on {h}"
            );
        }
    }
    let bay = hit_on(hits, &b.bay);
    assert_eq!(
        bay["attachment"],
        json!({ "name": b.field.name, "path": b.field.path }),
        "{what}: Bay's hit carries attachment"
    );
    assert_eq!(
        bay["snippet"],
        json!(format!("{} · {FIELD_TEXT}", b.field.name)),
        "{what}: Bay's snippet"
    );
    let alpha = hit_on(hits, &b.alpha);
    assert!(
        alpha.get("attachment").is_none(),
        "{what}: a plain hit has no attachment key: {alpha}"
    );
    let day = hit_on(hits, &b.day);
    assert_eq!(day["attachment"]["path"], json!(b.sketch.path), "{what}");
    assert_eq!(
        day["snippet"],
        json!(b.sketch.name),
        "{what}: name-only snippet"
    );
    let topic = hit_on(hits, &b.topic);
    assert_eq!(topic["via"], json!(DAY), "{what}");
    assert_eq!(topic["attachment"]["path"], json!(b.sketch.path), "{what}");

    let list = &v["attachments"];
    let field = entry(list, &b.field);
    assert_eq!(
        keys(field),
        key_set(&["name", "notes", "path", "size", "snippet", "type"]),
        "{what}"
    );
    assert_eq!(field["type"], json!("text/plain"), "{what}");
    assert_eq!(field["size"], json!(2048), "{what}");
    assert_eq!(field["snippet"], json!(FIELD_TEXT), "{what}");
    assert_eq!(field["notes"].as_array().map(Vec::len), Some(4), "{what}");
    let sketch = entry(list, &b.sketch);
    assert_eq!(
        keys(sketch),
        key_set(&["name", "notes", "path", "size", "type"]),
        "{what}: no snippet key for a name-only match"
    );
    assert_eq!(
        sketch["notes"],
        json!([{ "id": b.day.id.as_str(), "title": DAY }]),
        "{what}"
    );
}

/// A [`PLAIN_QUERY`] answer from `note_search` has exactly v0.6's keys.
fn assert_v06_note_search_body(v: &Value, b: &Built, what: &str) {
    assert_eq!(
        keys(v),
        key_set(&["hits", "query", "semantic", "truncated"]),
        "{what}: no attachments key without a match"
    );
    let hits = v["hits"].as_array().unwrap();
    assert_eq!(
        keys(hit_on(hits, &b.alpha)),
        key_set(&NOTE_HIT_KEYS),
        "{what}"
    );
}

// ---------------------------------------------------------------- servers

async fn get(srv: &TestServer, path: &str) -> Reply {
    let req = client()
        .get(srv.url(path))
        .header("authorization", format!("Bearer {TEST_TOKEN}"));
    Reply::read(req.send().await.expect("send request")).await
}

fn search_path(q: &str, limit: usize) -> String {
    format!("/vaults/{VAULT}/api/v1/search?q={q}&limit={limit}")
}

/// A port nothing listens on, for `HF_ENDPOINT`.
fn closed_port_url() -> String {
    let l = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    let url = format!("http://{}", l.local_addr().unwrap());
    drop(l);
    url
}

/// `memex search --vault <dir> --query <q> --limit <n>` as JSON.
fn cli_search(vault_dir: &Path, q: &str, limit: usize) -> Value {
    let out = Command::new(env!("CARGO_BIN_EXE_memex"))
        .args(["search", "--vault"])
        .arg(vault_dir)
        .args(["--query", q, "--limit", &limit.to_string()])
        .env("HF_ENDPOINT", closed_port_url())
        .env_remove("HF_HOME")
        .stdin(Stdio::null())
        .output()
        .expect("run memex search");
    assert!(
        out.status.success(),
        "memex search exits 0: {}",
        String::from_utf8_lossy(&out.stderr)
    );
    serde_json::from_slice(&out.stdout).unwrap_or_else(|e| {
        panic!(
            "stdout is JSON ({e}): {}",
            String::from_utf8_lossy(&out.stdout)
        )
    })
}

async fn mcp_search(state: &Arc<AppState>, q: &str) -> Value {
    let memex = Memex::new(state.clone());
    let out = memex
        .search(Parameters(SearchParams {
            query: q.into(),
            k: Some(LIMIT),
            mode: Some("fts".into()),
            tags: None,
            note_id: None,
        }))
        .await;
    serde_json::from_str(&out).unwrap_or_else(|e| panic!("tool output is JSON ({e}): {out}"))
}

fn fixture_path() -> PathBuf {
    api_v1_dir().join("search").join(FIXTURE)
}

// ================================================================ AC 8 (R48, compat)

#[test]
fn memex_search_cli_json_carries_attachment_fields_only_when_present() {
    let root = tempfile::tempdir().unwrap();
    let b = build_vault(root.path());

    let got = cli_search(&b.vault_dir, QUERY, LIMIT);
    assert_attachment_answer(&got, "hits", &b, "memex search");
    assert_eq!(got["truncated"], json!(false));

    let plain = cli_search(&b.vault_dir, PLAIN_QUERY, LIMIT);
    assert_v06_note_search_body(&plain, &b, "memex search, no attachment match");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn mcp_search_tool_output_carries_attachment_fields_only_when_present() {
    let root = tempfile::tempdir().unwrap();
    let b = build_vault(root.path());
    let vault = Vault::open(&b.vault_dir).unwrap();
    let state = Arc::new(AppState::new(vault, b.vault_dir.clone(), None));

    let got = mcp_search(&state, QUERY).await;
    assert_attachment_answer(&got, "results", &b, "MCP search");

    let plain = mcp_search(&state, PLAIN_QUERY).await;
    assert_eq!(
        keys(&plain),
        key_set(&["mode", "query", "results", "truncated", "vault_id"]),
        "MCP search, no attachment match: no attachments key"
    );
    let results = plain["results"].as_array().unwrap();
    assert_eq!(
        keys(hit_on(results, &b.alpha)),
        key_set(&[
            "chunk_id",
            "note_id",
            "note_title",
            "ord",
            "score",
            "snippet"
        ]),
        "MCP search: a plain hit keeps exactly its keys"
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn search_route_json_carries_attachment_fields_only_when_present() {
    let root = tempfile::tempdir().unwrap();
    let b = build_vault(root.path());
    let srv = TestServer::start_in(root).await;

    let reply = get(&srv, &search_path(QUERY, LIMIT)).await;
    assert_eq!(reply.status, 200, "{}", reply.body);
    let got = reply.json();
    assert_attachment_answer(&got, "hits", &b, "GET /search");
    assert_eq!(got["semantic"], json!("embeddings_off"));

    let reply = get(&srv, &search_path(PLAIN_QUERY, LIMIT)).await;
    assert_eq!(reply.status, 200, "{}", reply.body);
    assert_v06_note_search_body(&reply.json(), &b, "GET /search, no attachment match");
}

// ================================================================ AC 5 (R43, TD)

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn embeddings_route_counts_include_attachment_chunks_and_vectors() {
    let root = tempfile::tempdir().unwrap();
    let b = build_vault(root.path());
    {
        let conn = Connection::open(b.vault_dir.join("memex.db")).unwrap();
        // A second Field Notes chunk, so the attachment side has two.
        conn.execute(
            "INSERT INTO attachment_chunks (id, path, ord, content, token_count, embed_model_version)
             VALUES ('att-f1-1', ?, 1, 'Second page.', 2, NULL)",
            [&b.field.path],
        )
        .unwrap();
        let vault = Vault::open(&b.vault_dir).unwrap();
        let conn = vault.connection_ref();
        schema::ensure_vector_table(conn, 4).unwrap();
        schema::ensure_attachment_vector_table(conn, 4).unwrap();
        let v: Vec<u8> = [1.0_f32, 0.0, 0.0, 0.0]
            .iter()
            .flat_map(|f| f.to_le_bytes())
            .collect();
        let note_chunk: String = conn
            .query_row(
                "SELECT id FROM chunks WHERE note_id = ?",
                [b.alpha.id.as_str()],
                |r| r.get(0),
            )
            .unwrap();
        conn.execute(
            "INSERT INTO chunk_vec (chunk_id, embedding) VALUES (?, ?)",
            params![note_chunk, v],
        )
        .unwrap();
        conn.execute(
            "INSERT INTO attachment_chunk_vec (chunk_id, embedding) VALUES ('att-f1-0', ?)",
            params![v],
        )
        .unwrap();
    }
    let note_chunks: i64 = Connection::open(b.vault_dir.join("memex.db"))
        .unwrap()
        .query_row("SELECT COUNT(*) FROM chunks", [], |r| r.get(0))
        .unwrap();
    let srv = TestServer::start_in(root).await;

    let reply = get(&srv, &format!("/vaults/{VAULT}/api/v1/embeddings")).await;
    assert_eq!(reply.status, 200, "{}", reply.body);
    let got = reply.json();
    assert_eq!(
        got["chunks"],
        json!(note_chunks + 2),
        "chunks counts the two attachment chunks: {got}"
    );
    assert_eq!(
        got["embedded"],
        json!(2),
        "embedded counts the attachment vector: {got}"
    );
}

// ================================================================ AC 9 (D18)

#[test]
fn attachments_fixture_has_every_d18_branch() {
    let path = fixture_path();
    let text = std::fs::read_to_string(&path).unwrap_or_else(|e| {
        panic!(
            "{} exists (bless it with MEMEX_BLESS=1 cargo test -p memex-mcp --test \
             attachments_search_json): {e}",
            path.display()
        )
    });
    let v: Value = serde_json::from_str(&text).expect("the fixture is JSON");
    assert_eq!(text, canonical_json(&v), "stored in canonical form");
    assert_no_null_new_fields(&v, FIXTURE);
    let hits = v["hits"].as_array().expect("hits");
    for h in hits {
        assert!(h["chunk_id"].is_string(), "chunk_id: {h}");
        assert!(h["snippet"].is_string(), "snippet: {h}");
        assert!(
            h["note_updated_at"].is_i64(),
            "an integer note_updated_at: {h}"
        );
    }
    assert!(
        hits.iter()
            .any(|h| h["attachment"].is_object() && h["via"].is_null()),
        "a hit with attachment"
    );
    assert!(
        hits.iter().any(|h| h.get("attachment").is_none()),
        "a hit without attachment"
    );
    assert!(
        hits.iter()
            .any(|h| h["via"].is_string() && h["attachment"].is_object()),
        "a daily hit expanded with via, keeping attachment"
    );
    let list = v["attachments"].as_array().expect("attachments");
    assert!(
        list.iter().any(|a| a["snippet"].is_string()),
        "snippet present"
    );
    assert!(
        list.iter().any(|a| a.get("snippet").is_none()),
        "snippet absent"
    );
    assert!(
        list.iter()
            .any(|a| a["notes"].as_array().is_some_and(|n| n.len() > 3)),
        "an attachment in more than 3 notes"
    );
    for a in list {
        assert!(a["name"].is_string() && a["path"].is_string() && a["type"].is_string());
        assert!(a["size"].is_i64(), "size: {a}");
        for n in a["notes"].as_array().expect("notes") {
            assert_eq!(keys(n), key_set(&["id", "title"]));
        }
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn attachments_fixture_is_what_the_full_router_answers_for_its_seeded_vault() {
    let root = tempfile::tempdir().unwrap();
    let b = build_vault(root.path());
    let srv = TestServer::start_in(root).await;

    let reply = get(&srv, &search_path(QUERY, LIMIT)).await;
    assert_eq!(reply.status, 200, "{}", reply.body);
    let actual = reply.json();
    assert_attachment_answer(&actual, "hits", &b, "GET /search");
    let path = fixture_path();
    if bless_requested() {
        std::fs::write(&path, canonical_json(&actual)).unwrap();
        return;
    }
    let text = std::fs::read_to_string(&path)
        .unwrap_or_else(|e| panic!("{} exists (bless with MEMEX_BLESS=1): {e}", path.display()));
    let committed: Value = serde_json::from_str(&text).expect("the fixture is JSON");
    assert_eq!(
        canonical_json(&normalize_volatile(&committed)),
        canonical_json(&normalize_volatile(&actual)),
        "{FIXTURE} is the router's answer (rebless with MEMEX_BLESS=1)"
    );
}
