//! WI #137 (Spec #123 R43, R45-R49, TD "Search fusion"): search over
//! attachments.
//!
//! - Attachment chunk matches (`attachment_chunk_fts`, `attachment_chunk_vec`)
//!   and attachment name matches join the keyword and meaning fusion. Each
//!   match becomes one passage hit per note that references the attachment
//!   (`note_attachments`): its `chunk_id` is that note's chunk holding the
//!   reference line, its `start_byte` the line's offset, its snippet
//!   `<name> · <first 280 characters of the matched attachment chunk>` (or
//!   `<name>` for a name-only match), and it carries `attachment: {name,
//!   path}`. At most one hit per (note, attachment); daily-note hits expand
//!   to transcluding topics (`via`) keeping both. Attachment hits count
//!   toward `limit` and `truncated`.
//! - The results gain a top-level `attachments` list: each matching,
//!   referenced attachment once, in fused order, at most `limit`, as `{name,
//!   path, type, size, snippet?, notes: [{id, title}]}`.
//! - R45: the `objects/…` destination of a reference line is left out of
//!   `chunk_fts` and of the embedding input (reindex and `embed_missing`);
//!   `chunks.content` keeps the exact body slice, so Echoes are unchanged.
//! - `embed_missing` also fills `attachment_chunk_vec` and never deletes
//!   those vectors as orphans of `chunks`; `embedding_counts` include them.
//! - New JSON fields are omitted when absent, never `null`.
//!
//! The V9 attachment tables are seeded directly (no extraction, #136).
//! Real SQLite, real schema, temp vaults and invented names only. Test
//! embedders only, never a model download.

use std::collections::BTreeSet;
use std::sync::Mutex;

use memex_core::attachments;
use memex_core::echoes::echoes;
use memex_core::embedder::Embedder;
use memex_core::indexer;
use memex_core::note_search::{note_search, SearchEmbedder};
use memex_core::notes::{create_note_as, get_note, update_note, CreateNote, Note, UpdateNote};
use memex_core::search::{search, SearchFilters, SearchMode, SearchOptions};
use memex_core::vectors::{embed_missing, embedding_counts};
use memex_core::{Caller, Result, Vault};
use rusqlite::{params, Connection, OptionalExtension};
use serde_json::{json, Value};
use tempfile::TempDir;

const DIM: usize = 4;
const DAY: &str = "2026-09-05";
/// U+00B7 with a space on each side (R46).
const DOT: &str = " · ";
/// The characters of an attachment chunk a snippet keeps (R46).
const SNIPPET_CHARS: usize = 280;
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

// ---------------------------------------------------------------- embedders

fn axis(i: usize) -> Vec<f32> {
    let mut v = vec![0.0; DIM];
    v[i] = 1.0;
    v
}

/// Maps a text to an axis by its words: "zebra" or "striped" -> axis 0,
/// "kelp" -> axis 2, anything else -> axis 1. Records every text it embeds.
struct Words {
    texts: Mutex<Vec<String>>,
}

impl Words {
    fn new() -> Self {
        Self {
            texts: Mutex::new(Vec::new()),
        }
    }

    fn texts(&self) -> Vec<String> {
        self.texts.lock().unwrap().clone()
    }

    fn clear(&self) {
        self.texts.lock().unwrap().clear();
    }
}

impl Embedder for Words {
    fn model_version(&self) -> &str {
        "words-v1"
    }

    fn dimension(&self) -> usize {
        DIM
    }

    fn embed_batch(&self, texts: &[String]) -> Result<Vec<Vec<f32>>> {
        self.texts.lock().unwrap().extend(texts.iter().cloned());
        Ok(texts
            .iter()
            .map(|t| {
                let t = t.to_lowercase();
                if t.contains("zebra") || t.contains("striped") {
                    axis(0)
                } else if t.contains("kelp") {
                    axis(2)
                } else {
                    axis(1)
                }
            })
            .collect())
    }
}

// ---------------------------------------------------------------- vaults

fn fresh_vault() -> (TempDir, Vault) {
    let dir = tempfile::tempdir().unwrap();
    let vault = Vault::create(dir.path().join("My Vault")).unwrap();
    (dir, vault)
}

/// `n` filler words no test queries for.
fn filler(n: usize) -> String {
    const WORDS: [&str; 5] = ["lorem", "ipsum", "dolor", "sit", "amet"];
    (0..n)
        .map(|i| WORDS[i % WORDS.len()])
        .collect::<Vec<_>>()
        .join(" ")
}

fn create_with(vault: &mut Vault, title: &str, body: &str, fm: Option<Value>) -> Note {
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
    reindex(vault, note.id.as_str(), None);
    note
}

fn create(vault: &mut Vault, title: &str, body: &str) -> Note {
    create_with(vault, title, body, None)
}

/// Reindexes the note from its stored body, as every save does.
fn reindex(vault: &mut Vault, id: &str, embedder: Option<&dyn Embedder>) {
    let body = stored_body(vault.connection_ref(), id);
    indexer::reindex_note(vault.connection_mut(), id, &body, embedder)
        .unwrap_or_else(|e| panic!("reindex {id}: {e}"));
}

/// A person save of `body`, then the reindex.
fn save(vault: &mut Vault, note: &Note, body: &str) {
    let version = get_note(vault, &note.id).unwrap().version;
    update_note(
        vault,
        &note.id,
        version,
        UpdateNote {
            content_md: Some(body.into()),
            ..Default::default()
        },
    )
    .unwrap_or_else(|e| panic!("update {}: {e}", note.id));
    reindex(vault, note.id.as_str(), None);
}

fn stored_body(conn: &Connection, id: &str) -> String {
    conn.query_row("SELECT content_md FROM notes WHERE id = ?", [id], |r| {
        r.get(0)
    })
    .unwrap()
}

// ---------------------------------------------------------------- attachments

/// One seeded attachment: its stored name, decoded path, hash, MIME type,
/// size, R3 markdown and chunk ids.
#[derive(Clone)]
struct Att {
    name: String,
    path: String,
    hash: String,
    mime: String,
    size: i64,
    markdown: String,
    chunk_ids: Vec<String>,
}

impl Att {
    /// `{name, path}`: the hit's `attachment` (R48).
    fn hit_json(&self) -> Value {
        json!({ "name": self.name, "path": self.path })
    }
}

/// Seeds the V9 index rows of an attachment named `name` with hash `h2…`:
/// its `attachments` row (`done` with chunks, else `extract_state`) and one
/// `attachment_chunks` + `attachment_chunk_fts` row per chunk text. No
/// note references it yet.
fn seed_attachment_as(
    conn: &Connection,
    h2: &str,
    name: &str,
    size: i64,
    chunks: &[&str],
    extract_state: &str,
) -> Att {
    let hash = h2.repeat(32);
    let markdown = attachments::markdown_for(name, &hash);
    let path = attachments::parse_reference(&markdown)
        .unwrap_or_else(|| panic!("fixture: {markdown} is an R4 reference"))
        .target
        .path;
    let mime = attachments::mime_for(name).to_string();
    conn.execute(
        "INSERT INTO attachments (path, name, type, size, extract_state, extract_error, extracted_at)
         VALUES (?, ?, ?, ?, ?, NULL, 1790000000000)",
        params![path, name, mime, size, extract_state],
    )
    .expect("attachments exists (schema V9)");
    let mut chunk_ids = Vec::new();
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
        chunk_ids.push(id);
    }
    Att {
        name: name.to_string(),
        path,
        hash,
        mime,
        size,
        markdown,
        chunk_ids,
    }
}

fn seed_attachment(conn: &Connection, h2: &str, name: &str, size: i64, chunks: &[&str]) -> Att {
    let state = if chunks.is_empty() { "empty" } else { "done" };
    seed_attachment_as(conn, h2, name, size, chunks, state)
}

/// `(path, line_start_byte)` of a note's `note_attachments` rows.
fn refs(conn: &Connection, note_id: &str) -> Vec<(String, usize)> {
    let mut stmt = conn
        .prepare(
            "SELECT path, line_start_byte FROM note_attachments WHERE note_id = ?
             ORDER BY line_start_byte",
        )
        .unwrap();
    stmt.query_map([note_id], |r| {
        Ok((r.get::<_, String>(0)?, r.get::<_, i64>(1)? as usize))
    })
    .unwrap()
    .collect::<rusqlite::Result<_>>()
    .unwrap()
}

/// The byte offset of `att`'s reference line in `note`'s stored body, checked
/// against the note's `note_attachments` row (R49, written by the indexer).
fn line_start(conn: &Connection, note: &Note, att: &Att) -> usize {
    let body = stored_body(conn, note.id.as_str());
    let at = body
        .find(&att.markdown)
        .unwrap_or_else(|| panic!("fixture: {} holds {}", note.title, att.markdown));
    assert!(
        refs(conn, note.id.as_str()).contains(&(att.path.clone(), at)),
        "fixture: {}'s note_attachments row for {} is at {at}: {:?}",
        note.title,
        att.name,
        refs(conn, note.id.as_str())
    );
    at
}

/// `(id, ord)` of `note`'s chunk whose stored range holds byte `at`.
fn chunk_holding(conn: &Connection, note: &Note, at: usize) -> (String, i64) {
    conn.query_row(
        "SELECT id, ord FROM chunks
          WHERE note_id = ?1 AND start_byte <= ?2 AND ?2 < end_byte",
        params![note.id.as_str(), at as i64],
        |r| Ok((r.get(0)?, r.get(1)?)),
    )
    .optional()
    .unwrap()
    .unwrap_or_else(|| panic!("fixture: a chunk of {} holds byte {at}", note.title))
}

/// `(id, content, start_byte, end_byte)` of a note's chunks, by ord.
fn chunk_rows(conn: &Connection, note_id: &str) -> Vec<(String, String, i64, i64)> {
    let mut stmt = conn
        .prepare(
            "SELECT id, content, start_byte, end_byte FROM chunks WHERE note_id = ? ORDER BY ord",
        )
        .unwrap();
    stmt.query_map([note_id], |r| {
        Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?))
    })
    .unwrap()
    .collect::<rusqlite::Result<_>>()
    .unwrap()
}

// ---------------------------------------------------------------- searches

/// `note_search` (the CLI and server path) as JSON, keyword only.
fn ns(vault: &mut Vault, q: &str, limit: usize) -> Value {
    let mut conn: &mut Connection = vault.connection_mut();
    let got = note_search(&mut conn, q, limit, SearchEmbedder::Off, 0)
        .unwrap_or_else(|e| panic!("note_search {q:?}: {e}"));
    serde_json::to_value(got).unwrap()
}

/// `search::search` (the MCP path) as JSON, in `mode`.
fn core_search(vault: &Vault, q: &str, k: usize, mode: SearchMode) -> Value {
    let got = search(
        vault.connection_ref(),
        SearchOptions {
            query: q,
            k,
            mode,
            filters: SearchFilters::default(),
            embedder: None,
        },
    )
    .unwrap_or_else(|e| panic!("search {q:?}: {e}"));
    serde_json::to_value(got).unwrap()
}

fn hits(v: &Value) -> &Vec<Value> {
    v["hits"]
        .as_array()
        .unwrap_or_else(|| panic!("no hits array: {v}"))
}

/// The hits on `note`, in order.
fn hits_on<'a>(v: &'a Value, note: &Note) -> Vec<&'a Value> {
    hits(v)
        .iter()
        .filter(|h| h["note_id"] == json!(note.id.as_str()))
        .collect()
}

/// The single hit on `note`.
fn the_hit<'a>(v: &'a Value, note: &Note) -> &'a Value {
    let on = hits_on(v, note);
    assert_eq!(
        on.len(),
        1,
        "exactly one hit on {}: {}",
        note.title,
        serde_json::to_string_pretty(v).unwrap()
    );
    on[0]
}

/// The `attachments` list (absent = empty).
fn att_list(v: &Value) -> Vec<Value> {
    match v.get("attachments") {
        None => Vec::new(),
        Some(Value::Array(a)) => a.clone(),
        Some(other) => panic!("attachments is not an array: {other}"),
    }
}

fn att_paths(v: &Value) -> Vec<String> {
    att_list(v)
        .iter()
        .map(|a| a["path"].as_str().unwrap_or_default().to_string())
        .collect()
}

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

/// `{id, title}` of each note, sorted by id.
fn note_refs(notes: &[&Note]) -> Vec<Value> {
    let mut out: Vec<Value> = notes
        .iter()
        .map(|n| json!({ "id": n.id.as_str(), "title": n.title }))
        .collect();
    out.sort_by_key(|v| v["id"].as_str().unwrap().to_string());
    out
}

fn sorted_notes(entry: &Value) -> Vec<Value> {
    let mut out = entry["notes"]
        .as_array()
        .unwrap_or_else(|| panic!("no notes array: {entry}"))
        .clone();
    out.sort_by_key(|v| v["id"].as_str().unwrap_or_default().to_string());
    out
}

/// Asserts `snippet` is `<name> · ` + the first 280 characters of `content`,
/// optionally followed by one `…` when `content` is longer (R46).
fn assert_content_snippet(snippet: &Value, name: &str, content: &str) {
    let snippet = snippet
        .as_str()
        .unwrap_or_else(|| panic!("snippet is a string: {snippet}"));
    let first: String = content.chars().take(SNIPPET_CHARS).collect();
    let want = format!("{name}{DOT}{first}");
    let rest = snippet.strip_prefix(want.as_str()).unwrap_or_else(|| {
        panic!("snippet must start with {want:?}\n  got: {snippet:?}");
    });
    let longer = content.chars().count() > SNIPPET_CHARS;
    assert!(
        rest.is_empty() || (longer && rest == "…"),
        "snippet keeps only the first {SNIPPET_CHARS} characters of the chunk \
         (at most a trailing …): extra {rest:?}"
    );
}

/// A 400-character attachment chunk with multibyte characters around the
/// 280-character cut, saying "heron".
fn long_heron_text() -> String {
    let mut s = String::from("The heron stood still by the mill race. ");
    let pattern = ['é', '🦩', 'a', ' ', 'ü', 'b'];
    let mut i = 0;
    while s.chars().count() < 400 {
        s.push(pattern[i % pattern.len()]);
        i += 1;
    }
    assert!(s.len() > s.chars().count(), "multibyte text");
    s
}

// ================================================================ AC 1 (R46)

#[test]
fn content_match_gives_one_passage_hit_per_referencing_note_on_its_reference_line() {
    let (_d, mut vault) = fresh_vault();
    let text = long_heron_text();
    let att = seed_attachment(
        vault.connection_ref(),
        "c3",
        "Field Notes.txt",
        4096,
        &[text.as_str()],
    );
    // A: the reference line sits in a later chunk, past byte 0.
    let a_body = format!(
        "{}\n\n{}\n\n{}\n\n{}\n",
        filler(300),
        filler(300),
        att.markdown,
        filler(40)
    );
    let a = create(&mut vault, "Walk Log", &a_body);
    // B: one short chunk; the line starts after a first line.
    let b = create(
        &mut vault,
        "Mill Visit",
        &format!("Notes from the visit.\n{}\nBack home.\n", att.markdown),
    );
    let conn = vault.connection_ref();
    let a_line = line_start(conn, &a, &att);
    let b_line = line_start(conn, &b, &att);
    let (a_chunk, a_ord) = chunk_holding(conn, &a, a_line);
    let (b_chunk, _) = chunk_holding(conn, &b, b_line);
    assert!(
        a_ord > 0,
        "fixture: A's reference line is past A's first chunk"
    );
    assert!(b_line > 0, "fixture: B's reference line is not at byte 0");
    for (id, content, _, _) in chunk_rows(conn, a.id.as_str())
        .into_iter()
        .chain(chunk_rows(conn, b.id.as_str()))
    {
        assert!(
            !content.to_lowercase().contains("heron"),
            "fixture: note chunk {id} never says heron itself"
        );
    }

    let got = ns(&mut vault, "heron", 8);
    assert_eq!(
        hits(&got).len(),
        2,
        "one hit for A and one for B, nothing else: {got:#}"
    );
    for (note, chunk, line) in [(&a, &a_chunk, a_line), (&b, &b_chunk, b_line)] {
        let hit = the_hit(&got, note);
        assert_eq!(
            hit["attachment"],
            att.hit_json(),
            "{}: attachment",
            note.title
        );
        assert_content_snippet(&hit["snippet"], &att.name, &text);
        assert_eq!(
            hit["chunk_id"],
            json!(chunk),
            "{}: chunk_id is the note chunk holding the reference line",
            note.title
        );
        assert_eq!(
            hit["start_byte"],
            json!(line),
            "{}: start_byte is the reference line's offset",
            note.title
        );
        assert_eq!(hit["note_title"], json!(note.title));
        assert!(hit["note_updated_at"].is_i64(), "note_updated_at: {hit}");
    }

    // The MCP path (`search::search`) gives the same hits.
    let core = core_search(&vault, "heron", 8, SearchMode::Fts);
    for (note, chunk) in [(&a, &a_chunk), (&b, &b_chunk)] {
        let hit = the_hit(&core, note);
        assert_eq!(
            hit["attachment"],
            att.hit_json(),
            "{}: attachment",
            note.title
        );
        assert_eq!(hit["chunk_id"], json!(chunk), "{}: chunk_id", note.title);
        assert_content_snippet(&hit["snippet"], &att.name, &text);
    }
}

#[test]
fn short_attachment_chunk_snippet_is_the_name_a_middle_dot_and_the_whole_chunk() {
    let (_d, mut vault) = fresh_vault();
    let text = "Heron count: 4 adults, 2 young, Zoë counted.";
    let att = seed_attachment(vault.connection_ref(), "d4", "Count.csv", 120, &[text]);
    let n = create(
        &mut vault,
        "Survey",
        &format!("Survey day.\n\n{}\n", att.markdown),
    );

    let got = ns(&mut vault, "heron", 8);
    let hit = the_hit(&got, &n);
    assert_eq!(hit["snippet"], json!(format!("Count.csv · {text}")));
    assert_eq!(hit["attachment"], att.hit_json());
}

#[test]
fn search_filters_apply_to_attachment_hits_through_their_referencing_note() {
    let (_d, mut vault) = fresh_vault();
    let att = seed_attachment(
        vault.connection_ref(),
        "e2",
        "Shared.txt",
        10,
        &["heron in the reeds"],
    );
    let a = create(&mut vault, "Alpha", &format!("A.\n\n{}\n", att.markdown));
    let b = create(&mut vault, "Beta", &format!("B.\n\n{}\n", att.markdown));

    let got = search(
        vault.connection_ref(),
        SearchOptions {
            query: "heron",
            k: 8,
            mode: SearchMode::Fts,
            filters: SearchFilters {
                tags_all: Vec::new(),
                note_id: Some(b.id.as_str().to_string()),
            },
            embedder: None,
        },
    )
    .unwrap();
    let got = serde_json::to_value(got).unwrap();
    assert_eq!(the_hit(&got, &b)["attachment"], att.hit_json());
    assert!(hits_on(&got, &a).is_empty(), "note_id filter: {got:#}");
    assert_eq!(hits(&got).len(), 1);
}

// ================================================================ AC 2 (R46)

#[test]
fn name_only_match_gives_the_snippet_name() {
    let (_d, mut vault) = fresh_vault();
    let conn = vault.connection_ref();
    // No extracted text: found by name only (R44).
    let report = seed_attachment(conn, "e5", "Quarterly Report.pdf", 9000, &[]);
    let scan = seed_attachment_as(conn, "f6", "Broken Scan.pdf", 7000, &[], "failed");
    // Empty bracket text: the note's own text never says the name, so only
    // the attachment's name can match.
    let report_line = report.markdown.replacen("[Quarterly Report.pdf]", "[]", 1);
    let scan_line = scan.markdown.replacen("[Broken Scan.pdf]", "[]", 1);
    assert!(attachments::parse_reference(&report_line).is_some());
    let n = create(
        &mut vault,
        "Finance",
        &format!("Budget talk.\n\n{report_line}\n\n{scan_line}\n"),
    );

    let got = ns(&mut vault, "quarterly", 8);
    let hit = the_hit(&got, &n);
    assert_eq!(hit["snippet"], json!("Quarterly Report.pdf"));
    assert_eq!(hit["attachment"], report.hit_json());
    let body = stored_body(vault.connection_ref(), n.id.as_str());
    let line = body.find(&report_line).unwrap();
    assert_eq!(hit["start_byte"], json!(line));

    // A file whose extraction failed is still found by name (R44).
    let got = ns(&mut vault, "scan", 8);
    let hit = the_hit(&got, &n);
    assert_eq!(hit["snippet"], json!("Broken Scan.pdf"));
    assert_eq!(hit["attachment"], scan.hit_json());
}

#[test]
fn note_text_and_attachment_both_matching_give_exactly_one_hit_carrying_attachment() {
    let (_d, mut vault) = fresh_vault();
    let text = "A heron fished below the weir.";
    let att = seed_attachment(vault.connection_ref(), "a1", "Weir.txt", 300, &[text]);
    // One chunk holds both the note's own "heron" and the reference line.
    let short = create(
        &mut vault,
        "Weir Walk",
        &format!("The heron came back at dusk.\n\n{}\n", att.markdown),
    );
    // The note's own "heron" is in its first chunk, the reference line in a
    // later one.
    let long = create(
        &mut vault,
        "Long Weir Walk",
        &format!(
            "The heron came back. {}\n\n{}\n\n{}\n",
            filler(300),
            filler(300),
            att.markdown
        ),
    );
    let conn = vault.connection_ref();
    let short_line = line_start(conn, &short, &att);
    let (short_chunk, _) = chunk_holding(conn, &short, short_line);
    assert_eq!(chunk_rows(conn, short.id.as_str()).len(), 1, "fixture");
    assert!(chunk_rows(conn, long.id.as_str()).len() > 1, "fixture");

    for got in [
        ns(&mut vault, "heron", 8),
        core_search(&vault, "heron", 8, SearchMode::Fts),
    ] {
        for note in [&short, &long] {
            let hit = the_hit(&got, note);
            assert_eq!(hit["attachment"], att.hit_json(), "{}", note.title);
            assert_content_snippet(&hit["snippet"], &att.name, text);
        }
        assert_eq!(the_hit(&got, &short)["chunk_id"], json!(short_chunk));
    }
    let got = ns(&mut vault, "heron", 8);
    assert_eq!(the_hit(&got, &short)["start_byte"], json!(short_line));
}

#[test]
fn a_note_referencing_one_attachment_on_two_lines_gets_one_hit() {
    let (_d, mut vault) = fresh_vault();
    let att = seed_attachment(
        vault.connection_ref(),
        "b2",
        "Tide Table.txt",
        200,
        &["High heron tide at noon."],
    );
    let n = create(
        &mut vault,
        "Twice",
        &format!("First.\n{}\nMiddle.\n{}\n", att.markdown, att.markdown),
    );
    assert_eq!(
        refs(vault.connection_ref(), n.id.as_str()).len(),
        2,
        "fixture"
    );
    let lines: Vec<usize> = refs(vault.connection_ref(), n.id.as_str())
        .into_iter()
        .map(|(_, at)| at)
        .collect();

    let got = ns(&mut vault, "heron", 8);
    let hit = the_hit(&got, &n);
    assert_eq!(hit["attachment"], att.hit_json());
    let at = hit["start_byte"].as_u64().unwrap_or(u64::MAX) as usize;
    assert!(lines.contains(&at), "start_byte {at} is one of {lines:?}");
}

// ================================================================ AC 3 (R46)

#[test]
fn daily_note_attachment_hit_expands_to_the_transcluding_topic_with_via_keeping_attachment() {
    let (_d, mut vault) = fresh_vault();
    let text = "Heron nest count by the north pond.";
    let att = seed_attachment(
        vault.connection_ref(),
        "d1",
        "Pond Survey.txt",
        512,
        &[text],
    );
    let day = create_with(
        &mut vault,
        DAY,
        &format!(
            "Fixed the jump arc.\n\n{}\n\nSleep was bad.\n",
            att.markdown
        ),
        Some(json!({ "role": "daily" })),
    );
    // Pin the attachment line's block id, then transclude it from a topic.
    let n = vault
        .connection_ref()
        .execute(
            "UPDATE blocks SET block_id = 'p0nd01' WHERE note_id = ? AND ord = 1",
            [day.id.as_str()],
        )
        .unwrap();
    assert_eq!(n, 1, "fixture: the day has a second block");
    let topic = create_with(
        &mut vault,
        "Bird Topics",
        &format!("Birds.\n\n![[{DAY}#^p0nd01]]\n"),
        Some(json!({ "role": "topic" })),
    );
    let line = line_start(vault.connection_ref(), &day, &att);

    let got = ns(&mut vault, "heron", 8);
    let titles: Vec<&str> = hits(&got)
        .iter()
        .map(|h| h["note_title"].as_str().unwrap())
        .collect();
    assert_eq!(titles, vec![DAY, "Bird Topics"], "{got:#}");
    let d = the_hit(&got, &day);
    assert_eq!(d["attachment"], att.hit_json());
    assert_eq!(d["start_byte"], json!(line));
    assert_eq!(d["via"], Value::Null, "the daily hit itself has no via");
    let t = the_hit(&got, &topic);
    assert_eq!(t["via"], json!(DAY));
    assert_eq!(
        t["attachment"],
        att.hit_json(),
        "the topic hit keeps attachment"
    );
    assert_content_snippet(&t["snippet"], &att.name, text);
    assert_content_snippet(&d["snippet"], &att.name, text);

    let core = core_search(&vault, "heron", 8, SearchMode::Fts);
    let t = the_hit(&core, &topic);
    assert_eq!(t["via"], json!(DAY));
    assert_eq!(t["attachment"], att.hit_json());
    assert_content_snippet(&t["snippet"], &att.name, text);
}

// ================================================================ AC 4 (R47, R48, R49)

#[test]
fn attachments_list_holds_each_matching_attachment_once_in_fused_order_with_its_fields() {
    let (_d, mut vault) = fresh_vault();
    let conn = vault.connection_ref();
    // bm25 ranks X (short, three hits) above Y (one hit in a long chunk).
    let x_text = "heron heron heron.";
    let y_text = format!("The {} heron {}.", filler(60), filler(60));
    let x = seed_attachment(conn, "a7", "Field Notes.txt", 2048, &[x_text]);
    let y = seed_attachment(conn, "b8", "Mill Diary.md", 4000, &[y_text.as_str()]);
    let a = create(&mut vault, "Alpha", &format!("A.\n\n{}\n", x.markdown));
    let b = create(
        &mut vault,
        "Beta",
        &format!("B.\n\n{}\n\n{}\n", x.markdown, y.markdown),
    );

    let got = ns(&mut vault, "heron", 8);
    let list = att_list(&got);
    assert_eq!(
        att_paths(&got),
        vec![x.path.clone(), y.path.clone()],
        "each matching attachment once, in fused order: {got:#}"
    );
    let ex = &list[0];
    assert_eq!(
        keys(ex),
        key_set(&["name", "notes", "path", "size", "snippet", "type"])
    );
    assert_eq!(ex["name"], json!("Field Notes.txt"));
    assert_eq!(ex["type"], json!("text/plain"));
    assert_eq!(ex["type"], json!(x.mime));
    assert_eq!(ex["size"], json!(2048));
    assert_eq!(ex["snippet"], json!(x_text), "the matching text");
    assert_eq!(sorted_notes(ex), note_refs(&[&a, &b]));
    let ey = &list[1];
    assert_eq!(ey["name"], json!("Mill Diary.md"));
    assert_eq!(ey["size"], json!(y.size));
    assert_eq!(ey["type"], json!(y.mime));
    assert_eq!(sorted_notes(ey), note_refs(&[&b]));

    // At most `limit`, best first.
    let got = ns(&mut vault, "heron", 1);
    assert_eq!(att_paths(&got), vec![x.path.clone()]);

    // The MCP path carries the same list.
    let core = core_search(&vault, "heron", 8, SearchMode::Fts);
    assert_eq!(att_paths(&core), vec![x.path.clone(), y.path.clone()]);
}

#[test]
fn a_name_only_attachment_is_listed_without_a_snippet_and_with_every_referencing_note() {
    let (_d, mut vault) = fresh_vault();
    let sketch = seed_attachment(vault.connection_ref(), "c9", "Heron Sketch.png", 81234, &[]);
    let mut notes = Vec::new();
    for title in ["Bay", "Cove", "Dune", "Fen"] {
        notes.push(create(
            &mut vault,
            title,
            &format!("{title} trip.\n\n{}\n", sketch.markdown),
        ));
    }

    let got = ns(&mut vault, "sketch", 8);
    let list = att_list(&got);
    assert_eq!(list.len(), 1, "{got:#}");
    let entry = &list[0];
    assert_eq!(
        keys(entry),
        key_set(&["name", "notes", "path", "size", "type"]),
        "no snippet key for a name-only match (never null)"
    );
    assert_eq!(entry["name"], json!("Heron Sketch.png"));
    assert_eq!(entry["path"], json!(sketch.path));
    assert_eq!(entry["type"], json!("image/png"));
    assert_eq!(entry["size"], json!(81234));
    let all: Vec<&Note> = notes.iter().collect();
    assert_eq!(sorted_notes(entry), note_refs(&all), "all four notes");
    for n in &notes {
        assert_eq!(the_hit(&got, n)["attachment"], sketch.hit_json());
    }
}

#[test]
fn an_attachment_no_note_references_appears_neither_in_the_list_nor_as_a_hit() {
    let (_d, mut vault) = fresh_vault();
    let conn = vault.connection_ref();
    let kept = seed_attachment(conn, "a3", "Kept.txt", 10, &["heron kept"]);
    let dropped = seed_attachment(conn, "b4", "Dropped.txt", 10, &["heron dropped"]);
    let never = seed_attachment(conn, "c5", "Never.txt", 10, &["heron never"]);
    let keeper = create(&mut vault, "Keeper", &format!("K.\n\n{}\n", kept.markdown));
    let dropper = create(
        &mut vault,
        "Dropper",
        &format!("D.\n\n{}\n", dropped.markdown),
    );
    // The last line referencing Dropped.txt is removed.
    save(&mut vault, &dropper, "D, without the file.\n");
    assert!(refs(vault.connection_ref(), dropper.id.as_str()).is_empty());

    for got in [
        ns(&mut vault, "heron", 8),
        core_search(&vault, "heron", 8, SearchMode::Fts),
    ] {
        assert_eq!(att_paths(&got), vec![kept.path.clone()], "{got:#}");
        assert_eq!(the_hit(&got, &keeper)["attachment"], kept.hit_json());
        for h in hits(&got) {
            let path = &h["attachment"]["path"];
            assert_ne!(
                path,
                &json!(dropped.path),
                "no hit for an unreferenced file"
            );
            assert_ne!(
                path,
                &json!(never.path),
                "no hit for a never-referenced file"
            );
        }
        assert!(hits_on(&got, &dropper).is_empty());
    }
    // The unreferenced file keeps its extracted text (R49).
    let n: i64 = vault
        .connection_ref()
        .query_row(
            "SELECT COUNT(*) FROM attachment_chunks WHERE path = ?",
            [&dropped.path],
            |r| r.get(0),
        )
        .unwrap();
    assert_eq!(n, 1);
}

// ================================================================ AC 5 (R43, TD)

/// The chunk ids `attachment_chunk_vec` holds (empty when it doesn't exist).
fn attachment_vec_ids(conn: &Connection) -> BTreeSet<String> {
    let exists: bool = conn
        .query_row(
            "SELECT EXISTS (SELECT 1 FROM sqlite_master WHERE name = 'attachment_chunk_vec')",
            [],
            |r| r.get(0),
        )
        .unwrap();
    if !exists {
        return BTreeSet::new();
    }
    let mut stmt = conn
        .prepare("SELECT chunk_id FROM attachment_chunk_vec")
        .unwrap();
    stmt.query_map([], |r| r.get::<_, String>(0))
        .unwrap()
        .collect::<rusqlite::Result<_>>()
        .unwrap()
}

fn chunk_vec_ids(conn: &Connection) -> BTreeSet<String> {
    let mut stmt = conn.prepare("SELECT chunk_id FROM chunk_vec").unwrap();
    stmt.query_map([], |r| r.get::<_, String>(0))
        .unwrap()
        .collect::<rusqlite::Result<_>>()
        .unwrap()
}

#[test]
fn embed_missing_fills_attachment_chunk_vec_and_a_second_run_keeps_those_vectors() {
    let (_d, mut vault) = fresh_vault();
    let att = seed_attachment(
        vault.connection_ref(),
        "e7",
        "Reef.txt",
        900,
        &["A zebra fish over the reef.", "Kelp forest at low tide."],
    );
    create(
        &mut vault,
        "Dive",
        &format!("Dive day.\n\n{}\n", att.markdown),
    );
    let emb = Words::new();

    let first = {
        let mut conn: &mut Connection = vault.connection_mut();
        embed_missing(&mut conn, &emb, None, 0, 64).unwrap()
    };
    let conn = vault.connection_ref();
    let want: BTreeSet<String> = att.chunk_ids.iter().cloned().collect();
    assert_eq!(
        attachment_vec_ids(conn),
        want,
        "attachment_chunk_vec holds a vector per attachment chunk"
    );
    assert!(
        chunk_vec_ids(conn).is_disjoint(&want),
        "attachment vectors live in attachment_chunk_vec, not chunk_vec"
    );
    let embedded_texts = emb.texts();
    for t in ["A zebra fish over the reef.", "Kelp forest at low tide."] {
        assert!(
            embedded_texts.iter().any(|x| x == t),
            "the attachment chunk text {t:?} was embedded: {embedded_texts:?}"
        );
    }
    assert_eq!(first.pending, 0, "nothing left to embed");

    emb.clear();
    let second = {
        let mut conn: &mut Connection = vault.connection_mut();
        embed_missing(&mut conn, &emb, None, 0, 64).unwrap()
    };
    assert_eq!(
        attachment_vec_ids(vault.connection_ref()),
        want,
        "a second run deletes no attachment vector as an orphan of chunks"
    );
    assert_eq!(second.embedded, 0, "nothing re-embedded");
    assert!(emb.texts().is_empty(), "no embedder call on the second run");
}

#[test]
fn embedding_counts_include_attachment_chunks_and_their_vectors() {
    let (_d, mut vault) = fresh_vault();
    let att = seed_attachment(
        vault.connection_ref(),
        "f8",
        "Notes.md",
        64,
        &["first part", "second part", "third part"],
    );
    create(
        &mut vault,
        "Holder",
        &format!("Hold.\n\n{}\n", att.markdown),
    );
    let note_chunks: i64 = vault
        .connection_ref()
        .query_row("SELECT COUNT(*) FROM chunks", [], |r| r.get(0))
        .unwrap();
    assert!(note_chunks > 0, "fixture: the note has chunks");
    let before = embedding_counts(vault.connection_ref()).unwrap();
    assert_eq!(
        before.chunks,
        note_chunks + 3,
        "chunks counts note chunks and attachment chunks"
    );
    assert_eq!(before.embedded, 0);

    let emb = Words::new();
    {
        let mut conn: &mut Connection = vault.connection_mut();
        embed_missing(&mut conn, &emb, None, 0, 64).unwrap();
    }
    let after = embedding_counts(vault.connection_ref()).unwrap();
    assert_eq!(after.chunks, note_chunks + 3);
    assert_eq!(
        after.embedded, after.chunks,
        "embedded counts attachment vectors too"
    );
}

#[test]
fn meaning_search_finds_attachment_text_after_embed_missing() {
    let (_d, mut vault) = fresh_vault();
    let text = "A zebra crossed the river at dawn.";
    let att = seed_attachment(vault.connection_ref(), "a9", "River Log.txt", 333, &[text]);
    let n = create(
        &mut vault,
        "Morning",
        &format!("Morning walk.\n\n{}\n", att.markdown),
    );
    create(&mut vault, "Other", "Market day, bread and cheese.");
    let emb = Words::new();

    // "striped" shares no word with any text: only the vector arm finds it.
    let got = {
        let mut conn: &mut Connection = vault.connection_mut();
        note_search(&mut conn, "striped", 8, SearchEmbedder::Ready(&emb), 64).unwrap()
    };
    let got = serde_json::to_value(got).unwrap();
    assert_eq!(got["semantic"], json!("on"));
    let hit = hits_on(&got, &n)
        .into_iter()
        .find(|h| h.get("attachment").is_some())
        .unwrap_or_else(|| panic!("a meaning hit from River Log.txt on Morning: {got:#}"));
    assert_eq!(hit["attachment"], att.hit_json());
    assert_content_snippet(&hit["snippet"], &att.name, text);
    assert!(att_paths(&got).contains(&att.path));
    assert!(
        !attachment_vec_ids(vault.connection_ref()).is_empty(),
        "note_search's pending embedding filled attachment_chunk_vec"
    );
}

// ================================================================ AC 6 (R45)

#[test]
fn a_hash_or_objects_path_fragment_matches_nothing_and_chunks_keep_the_exact_body() {
    let (_d, mut vault) = fresh_vault();
    let att = seed_attachment(vault.connection_ref(), "c3", "Field Notes.txt", 10, &[]);
    let n = create(
        &mut vault,
        "Paths",
        &format!("Before the file.\n{}\nAfter the file.\n", att.markdown),
    );
    let body = stored_body(vault.connection_ref(), n.id.as_str());
    assert!(
        att.markdown.contains("Field%20Notes.txt"),
        "fixture: encoded"
    );

    let full = format!("objects/c3/{}", att.hash);
    for q in [att.hash.as_str(), "objects", "c3", "20Notes", full.as_str()] {
        for got in [
            ns(&mut vault, q, 8),
            core_search(&vault, q, 8, SearchMode::Fts),
        ] {
            assert!(hits(&got).is_empty(), "{q:?} matches no passage: {got:#}");
            assert!(att_list(&got).is_empty(), "{q:?} matches no attachment");
        }
    }
    // The bracketed name stays indexed.
    let got = ns(&mut vault, "field", 8);
    assert_eq!(
        hits_on(&got, &n).len(),
        1,
        "the bracketed name still matches"
    );

    // chunk_fts holds no destination; chunks.content keeps the exact slice.
    let conn = vault.connection_ref();
    for (id, content, s, e) in chunk_rows(conn, n.id.as_str()) {
        assert_eq!(
            body.get(s as usize..e as usize),
            Some(content.as_str()),
            "chunk {id} content is the exact body slice"
        );
        let fts: String = conn
            .query_row(
                "SELECT content FROM chunk_fts WHERE chunk_id = ?",
                [&id],
                |r| r.get(0),
            )
            .unwrap();
        assert!(!fts.contains("objects/"), "chunk_fts text: {fts:?}");
        assert!(!fts.contains(&att.hash), "chunk_fts text: {fts:?}");
        assert!(fts.contains("[Field Notes.txt]"), "chunk_fts text: {fts:?}");
        assert!(fts.contains("Before the file.") && fts.contains("After the file."));
    }
    assert!(
        chunk_rows(conn, n.id.as_str())
            .iter()
            .any(|(_, c, _, _)| c.contains(&att.markdown)),
        "chunks.content keeps the destination"
    );
}

#[test]
fn embedding_input_leaves_out_the_objects_destination_in_reindex_and_embed_missing() {
    let (_d, mut vault) = fresh_vault();
    let att = seed_attachment(vault.connection_ref(), "d6", "Field Notes.txt", 10, &[]);
    let body = format!("Before the file.\n{}\nAfter the file.\n", att.markdown);
    let n = create(&mut vault, "Embedded", &body);

    let check = |texts: &[String], what: &str| {
        let note_texts: Vec<&String> = texts
            .iter()
            .filter(|t| t.contains("Before the file."))
            .collect();
        assert!(
            !note_texts.is_empty(),
            "{what}: the note chunk was embedded: {texts:?}"
        );
        for t in note_texts {
            assert!(!t.contains("objects/"), "{what}: embedding input {t:?}");
            assert!(!t.contains(&att.hash), "{what}: embedding input {t:?}");
            assert!(
                t.contains("[Field Notes.txt]"),
                "{what}: embedding input {t:?}"
            );
        }
    };

    // embed_missing over the unembedded chunk.
    let emb = Words::new();
    {
        let mut conn: &mut Connection = vault.connection_mut();
        embed_missing(&mut conn, &emb, None, 0, 64).unwrap();
    }
    check(&emb.texts(), "embed_missing");

    // Reindex with an embedder.
    let emb = Words::new();
    reindex(&mut vault, n.id.as_str(), Some(&emb));
    check(&emb.texts(), "reindex");
    let stored = stored_body(vault.connection_ref(), n.id.as_str());
    assert!(
        chunk_rows(vault.connection_ref(), n.id.as_str())
            .iter()
            .any(|(_, c, _, _)| c.contains(&att.markdown) && stored.contains(c.as_str())),
        "chunks.content still holds the exact reference line"
    );
}

#[test]
fn echoes_are_unchanged_for_a_note_with_an_attachment_line() {
    let (_d, mut vault) = fresh_vault();
    let att = seed_attachment(
        vault.connection_ref(),
        "e9",
        "Herd.txt",
        10,
        &["zebra stripes in the attachment"],
    );
    let open = create(&mut vault, "Crossing", "Zebra crossing at the market.");
    let echo_body = format!("{}\n\nA zebra herd at dusk.\n", att.markdown);
    let echo = create(&mut vault, "Herd", &echo_body);
    let stored = stored_body(vault.connection_ref(), echo.id.as_str());
    let at = stored.find("A zebra herd at dusk.").unwrap();
    let emb = Words::new();

    let got = {
        let mut conn: &mut Connection = vault.connection_mut();
        echoes(&mut conn, &emb, open.id.as_str(), 8, 64).unwrap()
    };
    let ids: Vec<&str> = got.echoes.iter().map(|e| e.note_id.as_str()).collect();
    assert_eq!(ids, vec![echo.id.as_str()], "only the Herd note echoes");
    let e = &got.echoes[0];
    assert_eq!(e.passage, "A zebra herd at dusk.");
    assert_eq!(e.start_byte, Some(at), "the passage offset in the body");
    assert_eq!(
        stored.get(at..at + e.passage.len()),
        Some(e.passage.as_str())
    );
}

// ================================================================ AC 7 (R46)

#[test]
fn attachment_hits_count_toward_limit_and_set_truncated_when_they_push_past_it() {
    let (_d, mut vault) = fresh_vault();
    let att = seed_attachment(
        vault.connection_ref(),
        "f1",
        "Feathers.txt",
        10,
        &["heron feathers"],
    );
    let p = create(&mut vault, "Pier", "A heron by the pier.");
    let a = create(&mut vault, "Alpha", &format!("A.\n\n{}\n", att.markdown));
    let b = create(&mut vault, "Beta", &format!("B.\n\n{}\n", att.markdown));

    let all = ns(&mut vault, "heron", 3);
    assert_eq!(hits(&all).len(), 3, "P, A and B: {all:#}");
    assert_eq!(
        all["truncated"],
        json!(false),
        "exactly limit: not truncated"
    );
    for note in [&p, &a, &b] {
        the_hit(&all, note);
    }

    for got in [
        ns(&mut vault, "heron", 2),
        core_search(&vault, "heron", 2, SearchMode::Fts),
    ] {
        assert_eq!(hits(&got).len(), 2, "attachment hits count toward limit");
        assert_eq!(got["truncated"], json!(true), "they push past it");
    }
    let one = ns(&mut vault, "heron", 1);
    assert_eq!(hits(&one).len(), 1);
    assert_eq!(one["truncated"], json!(true));
}

// ================================================================ AC 8 (R48, compat)

#[test]
fn note_search_json_carries_the_new_fields_only_when_present_and_never_null() {
    let (_d, mut vault) = fresh_vault();
    let conn = vault.connection_ref();
    let field = seed_attachment(conn, "a2", "Field Notes.txt", 50, &["heron on the bank"]);
    let sketch = seed_attachment(conn, "b3", "Heron Sketch.png", 70, &[]);
    let with = create(
        &mut vault,
        "With",
        &format!("W.\n\n{}\n\n{}\n", field.markdown, sketch.markdown),
    );
    let plain = create(&mut vault, "Plain", "A heron, in plain words.");

    let got = ns(&mut vault, "heron", 8);
    assert_eq!(
        keys(&got),
        key_set(&["attachments", "hits", "query", "semantic", "truncated"])
    );
    let w = hits_on(&got, &with);
    assert!(!w.is_empty(), "{got:#}");
    for h in &w {
        let mut want = key_set(&NOTE_HIT_KEYS);
        want.insert("attachment".into());
        assert_eq!(keys(h), want, "an attachment hit keeps every v0.6 key");
        assert!(h["chunk_id"].is_string() && h["snippet"].is_string());
        assert!(h["note_updated_at"].is_i64());
        assert_eq!(keys(&h["attachment"]), key_set(&["name", "path"]));
    }
    let p = the_hit(&got, &plain);
    assert_eq!(
        keys(p),
        key_set(&NOTE_HIT_KEYS),
        "no attachment key, never null"
    );
    let list = att_list(&got);
    let by_path = |path: &str| {
        list.iter()
            .find(|a| a["path"] == json!(path))
            .unwrap_or_else(|| panic!("{path} listed: {got:#}"))
            .clone()
    };
    assert!(by_path(&field.path)["snippet"].is_string());
    assert!(
        by_path(&sketch.path).get("snippet").is_none(),
        "a name-only entry has no snippet key"
    );

    // No attachment matches: exactly the v0.6 body keys.
    let got = ns(&mut vault, "plain", 8);
    assert_eq!(
        keys(&got),
        key_set(&["hits", "query", "semantic", "truncated"]),
        "no attachments key when none matched"
    );
    assert_eq!(keys(the_hit(&got, &plain)), key_set(&NOTE_HIT_KEYS));

    // The MCP path: an attachment-free hit has only the legacy keys.
    let core = core_search(&vault, "plain", 8, SearchMode::Fts);
    assert_eq!(keys(&core), key_set(&["hits", "truncated"]));
    assert_eq!(
        keys(the_hit(&core, &plain)),
        key_set(&[
            "chunk_id",
            "note_id",
            "note_title",
            "ord",
            "score",
            "snippet"
        ])
    );
    let core = core_search(&vault, "heron", 8, SearchMode::Fts);
    assert_eq!(keys(&core), key_set(&["attachments", "hits", "truncated"]));
    assert!(the_hit(&core, &plain).get("attachment").is_none());
}

// ================================================================ AC 9 (D18, fixture determinism)

#[test]
fn hits_and_attachments_come_in_the_same_order_on_every_search() {
    let (_d, mut vault) = fresh_vault();
    let conn = vault.connection_ref();
    // Equal fused scores: one attachment chunk matched for four notes, and
    // a note chunk and an attachment chunk at the same rank of their lists.
    let x = seed_attachment(conn, "a4", "Survey.txt", 10, &["heron survey"]);
    let y = seed_attachment(conn, "b5", "Heron Map.png", 10, &[]);
    create(&mut vault, "Plain", "A heron, in plain words.");
    for title in ["Bay", "Cove", "Dune", "Fen"] {
        create(
            &mut vault,
            title,
            &format!("{title}.\n\n{}\n\n{}\n", x.markdown, y.markdown),
        );
    }

    let first = ns(&mut vault, "heron", 20);
    assert!(
        hits(&first)
            .iter()
            .filter(|h| h.get("attachment").is_some())
            .count()
            >= 4,
        "the four notes' attachment hits: {first:#}"
    );
    assert_eq!(att_list(&first).len(), 2);
    for i in 0..20 {
        assert_eq!(ns(&mut vault, "heron", 20), first, "run {i} differs");
        let core = core_search(&vault, "heron", 20, SearchMode::Fts);
        let again = core_search(&vault, "heron", 20, SearchMode::Fts);
        assert_eq!(core, again, "search::search run {i} differs");
    }
}
