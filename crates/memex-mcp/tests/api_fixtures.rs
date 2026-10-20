//! WI #74 (C0): wire-contract fixture infrastructure and the frozen seed vault
//! (rulings D10, D10a).
//!
//! These tests pin the support module `tests/support/api_fixtures.rs`, which
//! every serving WI (#72, #81–#85, #94) uses to check its
//! `app/test/fixtures/api_v1/<domain>/index.json` rows. The support module's
//! public surface, as used here:
//!
//! ```text
//! pub const SEED_VAULT_NAME: &str;            // fixed vault name in every row path
//! pub fn api_v1_dir() -> PathBuf;             // <repo>/app/test/fixtures/api_v1
//! pub fn bless_requested() -> bool;           // MEMEX_BLESS == "1"
//! pub fn seed_bless_requested() -> bool;      // MEMEX_BLESS == "1" && MEMEX_BLESS_SEED == "1"
//! pub fn materialize_seed(root: &Path) -> PathBuf;  // creates <root>/<SEED_VAULT_NAME>/
//! pub fn run_seed_builder(api_v1_dir: &Path, scratch: &Path, bless: bool) -> PathBuf;
//!     // builds the seed with memex-core and writes seed_vault.sql + seed_manifest.json
//!     // into api_v1_dir when bless, else into scratch; returns the dir it wrote
//! pub struct FixtureRow { method, path, request: Option<String>, response: String,
//!                         status: u16, headers: BTreeMap<String, String>, dart_only: bool }
//! pub fn load_rows(domain_dir: &Path) -> Result<Vec<FixtureRow>, String>;
//! pub struct FixtureRequest { method, path, headers: BTreeMap<String, String>,
//!                             body: Option<Vec<u8>> }       // body = request file bytes
//! pub struct FixtureResponse { pub status: u16, pub body: Vec<u8> }
//! pub fn run_rows(domain_dir: &Path, bless: bool,
//!                 exec: impl FnMut(&FixtureRequest) -> FixtureResponse) -> Result<(), String>;
//! pub fn canonical_json(v: &serde_json::Value) -> String;
//! pub fn normalize_volatile(v: &serde_json::Value) -> serde_json::Value;  // against the committed seed
//! pub struct UtcOffsetCases { valid: BTreeMap<String, i32>, invalid: Vec<String>,
//!                             format: BTreeMap<i32, String> }
//! pub fn load_utc_offsets() -> UtcOffsetCases;
//! ```
//!
//! Rows are named `<domain>[<zero-based index>]` in errors; the domain is the
//! folder name. The seed SQL holds one `INSERT INTO <table>` statement per row.

#[path = "support/api_fixtures.rs"]
mod api_fixtures;

use std::collections::{BTreeMap, HashMap};
use std::fs;
use std::path::{Path, PathBuf};

use api_fixtures::{
    api_v1_dir, canonical_json, load_rows, load_utc_offsets, materialize_seed, normalize_volatile,
    run_rows, run_seed_builder, seed_bless_requested, FixtureRequest, FixtureResponse, FixtureRow,
    SEED_VAULT_NAME,
};
use memex_core::Vault;
use regex::Regex;
use rusqlite::types::Value as SqlValue;
use rusqlite::Connection;
use serde_json::{json, Value};

// ---------------------------------------------------------------------------
// Helpers (test-local; they read the committed files directly, not through the
// support module, so a loader bug can't hide behind itself).
// ---------------------------------------------------------------------------

fn schema_sql() -> String {
    let path =
        Path::new(env!("CARGO_MANIFEST_DIR")).join("../../app/test/fixtures/vault_schema_v5.sql");
    fs::read_to_string(&path).unwrap_or_else(|e| panic!("read {}: {e}", path.display()))
}

fn committed_api_v1_dir() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../../app/test/fixtures/api_v1")
}

fn committed_seed_sql() -> String {
    let path = committed_api_v1_dir().join("seed_vault.sql");
    fs::read_to_string(&path).unwrap_or_else(|e| panic!("read {}: {e}", path.display()))
}

fn committed_seed_vault_id() -> String {
    let path = committed_api_v1_dir().join("seed_manifest.json");
    let raw = fs::read_to_string(&path).unwrap_or_else(|e| panic!("read {}: {e}", path.display()));
    let v: Value = serde_json::from_str(&raw).expect("seed_manifest.json is JSON");
    v["vault_id"]
        .as_str()
        .expect("seed_manifest.json has a string vault_id")
        .to_string()
}

fn is_ulid(s: &str) -> bool {
    Regex::new(r"^[0-7][0-9A-HJKMNP-TV-Z]{25}$")
        .unwrap()
        .is_match(s)
}

/// A plain in-memory SQLite database: the V5 schema fixture plus `seed_sql`.
fn load_on_schema(seed_sql: &str) -> Connection {
    let conn = Connection::open_in_memory().unwrap();
    conn.execute_batch(&schema_sql())
        .expect("vault_schema_v5.sql loads");
    conn.execute_batch(seed_sql)
        .expect("seed SQL loads on top of vault_schema_v5.sql");
    conn
}

/// Split SQL into statements on `;` outside quotes, dropping `--` comments.
fn split_sql(sql: &str) -> Vec<String> {
    let mut out = Vec::new();
    let mut cur = String::new();
    let mut chars = sql.chars().peekable();
    let (mut in_single, mut in_double) = (false, false);
    while let Some(c) = chars.next() {
        if in_single {
            cur.push(c);
            if c == '\'' {
                if chars.peek() == Some(&'\'') {
                    cur.push(chars.next().unwrap());
                } else {
                    in_single = false;
                }
            }
            continue;
        }
        if in_double {
            cur.push(c);
            if c == '"' {
                in_double = false;
            }
            continue;
        }
        match c {
            '\'' => {
                in_single = true;
                cur.push(c);
            }
            '"' => {
                in_double = true;
                cur.push(c);
            }
            '-' if chars.peek() == Some(&'-') => {
                while let Some(&n) = chars.peek() {
                    if n == '\n' {
                        break;
                    }
                    chars.next();
                }
            }
            ';' => {
                let s = cur.trim();
                if !s.is_empty() {
                    out.push(s.to_string());
                }
                cur.clear();
            }
            _ => cur.push(c),
        }
    }
    let s = cur.trim();
    if !s.is_empty() {
        out.push(s.to_string());
    }
    out
}

/// Table of an `INSERT INTO <table>` statement, or None for anything else.
fn insert_table(stmt: &str) -> Option<String> {
    let re =
        Regex::new(r#"(?is)^INSERT\s+(?:OR\s+\w+\s+)?INTO\s+"?([A-Za-z_][A-Za-z0-9_]*)"?[\s(]"#)
            .unwrap();
    re.captures(stmt).map(|c| c[1].to_string())
}

/// Number of `INSERT` statements per table in `seed_sql`.
fn insert_counts(seed_sql: &str) -> BTreeMap<String, i64> {
    let mut counts = BTreeMap::new();
    for stmt in split_sql(seed_sql) {
        if let Some(t) = insert_table(&stmt) {
            *counts.entry(t).or_insert(0) += 1;
        }
    }
    counts
}

/// Tables the app's schema fixture creates (the app-visible tables).
fn app_visible_tables() -> Vec<String> {
    let re = Regex::new(r"(?m)^CREATE TABLE ([A-Za-z_][A-Za-z0-9_]*)").unwrap();
    re.captures_iter(&schema_sql())
        .map(|c| c[1].to_string())
        .collect()
}

fn count(conn: &Connection, table: &str) -> i64 {
    conn.query_row(&format!("SELECT COUNT(*) FROM \"{table}\""), [], |r| {
        r.get(0)
    })
    .unwrap()
}

fn columns(conn: &Connection, table: &str) -> Vec<String> {
    let mut stmt = conn
        .prepare("SELECT name FROM pragma_table_info(?1) ORDER BY cid")
        .unwrap();
    let rows = stmt.query_map([table], |r| r.get::<_, String>(0)).unwrap();
    rows.map(|r| r.unwrap()).collect()
}

/// Every row of `table` (columns `cols`), as comparable strings.
fn rows_of(conn: &Connection, table: &str, cols: &[String]) -> Vec<String> {
    let list = cols
        .iter()
        .map(|c| format!("\"{c}\""))
        .collect::<Vec<_>>()
        .join(", ");
    let mut stmt = conn
        .prepare(&format!("SELECT {list} FROM \"{table}\""))
        .unwrap();
    let n = cols.len();
    let rows = stmt
        .query_map([], |r| {
            let mut vals = Vec::with_capacity(n);
            for i in 0..n {
                vals.push(r.get::<_, SqlValue>(i)?);
            }
            Ok(format!("{vals:?}"))
        })
        .unwrap();
    rows.map(|r| r.unwrap()).collect()
}

/// The first non-blank line after stripping heading markers, exactly as the
/// app's `VaultDb._snippet` computes it before the 120-unit cut.
fn snippet_source_line(content: &str) -> String {
    let stripped = Regex::new(r"(?m)^#+\s*").unwrap().replace_all(content, "");
    stripped
        .split('\n')
        .find(|l| !l.trim().is_empty())
        .unwrap_or("")
        .to_string()
}

/// Assert the D10 edge rows are present in a database holding the seed.
fn assert_seed_edge_rows(conn: &Connection, what: &str) {
    let notes: Vec<(String, String, String)> = {
        let mut stmt = conn
            .prepare("SELECT id, title, content_md FROM notes ORDER BY id")
            .unwrap();
        let rows = stmt
            .query_map([], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)))
            .unwrap();
        rows.map(|r| r.unwrap()).collect()
    };

    // 1. A note whose snippet comes from a heading-prefixed first line.
    let heading = Regex::new(r"^#{1,6}\s+\S").unwrap();
    assert!(
        notes.iter().any(|(_, _, c)| c
            .split('\n')
            .find(|l| !l.trim().is_empty())
            .is_some_and(|l| heading.is_match(l))),
        "{what}: no note whose first line is a heading (# …)"
    );

    // 2. Longer than 120 characters, with a surrogate pair straddling the
    //    120-UTF-16-unit cut (high surrogate at unit 119, low at unit 120).
    assert!(
        notes.iter().any(|(_, _, c)| {
            let line = snippet_source_line(c);
            let units: Vec<u16> = line.encode_utf16().collect();
            units.len() > 120
                && line.chars().count() > 120
                && (0xD800..=0xDBFF).contains(&units[119])
                && (0xDC00..=0xDFFF).contains(&units[120])
        }),
        "{what}: no note whose snippet line is over 120 characters with a surrogate pair at UTF-16 units 119-120"
    );

    // 3. A ghost link: no target note, and no note has its text as a title.
    let titles: Vec<String> = notes.iter().map(|(_, t, _)| t.to_lowercase()).collect();
    let ghost_texts: Vec<String> = {
        let mut stmt = conn
            .prepare("SELECT link_text FROM links WHERE to_note_id IS NULL")
            .unwrap();
        let rows = stmt.query_map([], |r| r.get::<_, String>(0)).unwrap();
        rows.map(|r| r.unwrap()).collect()
    };
    assert!(
        ghost_texts
            .iter()
            .any(|t| !titles.contains(&t.to_lowercase())),
        "{what}: no ghost link (to_note_id NULL, text matching no note title): {ghost_texts:?}"
    );

    // 4. An unreviewed daily note (no review row, or never reviewed).
    let unreviewed: i64 = conn
        .query_row(
            "SELECT COUNT(*) FROM notes n LEFT JOIN day_reviews r ON r.note_id = n.id
             WHERE json_valid(n.frontmatter)
               AND json_extract(n.frontmatter, '$.role') = 'daily'
               AND (r.note_id IS NULL OR r.reviewed_content_version IS NULL)",
            [],
            |r| r.get(0),
        )
        .unwrap();
    assert!(unreviewed > 0, "{what}: no unreviewed daily note");

    // 5. A pinned Smart Folder.
    let pinned: i64 = conn
        .query_row(
            "SELECT COUNT(*) FROM smart_folders WHERE pinned = 1",
            [],
            |r| r.get(0),
        )
        .unwrap();
    assert!(pinned > 0, "{what}: no pinned Smart Folder");
}

/// Every file under `dir`, path → bytes.
fn snapshot(dir: &Path) -> BTreeMap<PathBuf, Vec<u8>> {
    let mut out = BTreeMap::new();
    let mut stack = vec![dir.to_path_buf()];
    while let Some(d) = stack.pop() {
        for entry in fs::read_dir(&d).unwrap() {
            let p = entry.unwrap().path();
            if p.is_dir() {
                stack.push(p);
            } else {
                out.insert(p.clone(), fs::read(&p).unwrap());
            }
        }
    }
    out
}

/// Create `<parent>/<domain>/` with `index.json` and the given files.
fn write_domain(parent: &Path, domain: &str, index_json: &str, files: &[(&str, &str)]) -> PathBuf {
    let dir = parent.join(domain);
    fs::create_dir_all(&dir).unwrap();
    fs::write(dir.join("index.json"), index_json).unwrap();
    for (name, body) in files {
        fs::write(dir.join(name), body).unwrap();
    }
    dir
}

fn response(status: u16, body: Value) -> FixtureResponse {
    FixtureResponse {
        status,
        body: serde_json::to_vec(&body).unwrap(),
    }
}

fn row_fields(r: &FixtureRow) -> String {
    format!(
        "{} {} {:?} {} {} {:?} {}",
        r.method, r.path, r.request, r.response, r.status, r.headers, r.dart_only
    )
}

fn err_of<T>(r: Result<T, String>, what: &str) -> String {
    match r {
        Ok(_) => panic!("{what}: expected an error"),
        Err(e) => e,
    }
}

// Minted values that the seed can't contain (checked in each test).
const MINT_A: &str = "01KAZZZZZZZZZZZZZZZZZZZZZ1";
const MINT_B: &str = "01KAZZZZZZZZZZZZZZZZZZZZZ2";
const MINT_C: &str = "01KAZZZZZZZZZZZZZZZZZZZZZ3";
const MINT_D: &str = "01KAZZZZZZZZZZZZZZZZZZZZZ4";
const TS_1: i64 = 1_893_456_000_123;
const TS_2: i64 = 1_893_456_999_456;

fn assert_not_in_seed(values: &[&str]) {
    let seed = committed_seed_sql();
    for v in values {
        assert!(!seed.contains(v), "{v} must not occur in the seed");
    }
}

/// A seed note id and its created_at, from the committed seed.
fn a_seed_note() -> (String, i64) {
    let conn = load_on_schema(&committed_seed_sql());
    conn.query_row(
        "SELECT id, created_at FROM notes ORDER BY id LIMIT 1",
        [],
        |r| Ok((r.get(0)?, r.get(1)?)),
    )
    .expect("the seed has a note")
}

// ---------------------------------------------------------------------------
// AC1 + AC2: seed loader
// ---------------------------------------------------------------------------

#[test]
fn seed_loader_materializes_the_committed_seed_as_a_vault_folder() {
    let root = tempfile::tempdir().unwrap();
    let dir = materialize_seed(root.path());
    assert_eq!(dir, root.path().join(SEED_VAULT_NAME));
    assert!(dir.join("manifest.json").is_file(), "manifest.json written");
    assert!(dir.join("memex.db").is_file(), "memex.db written");

    let manifest: Value =
        serde_json::from_slice(&fs::read(dir.join("manifest.json")).unwrap()).unwrap();
    let frozen_id = committed_seed_vault_id();
    assert!(
        is_ulid(&frozen_id),
        "frozen vault_id is a ULID: {frozen_id}"
    );
    assert_eq!(manifest["vault_id"], json!(frozen_id));

    let vault = Vault::open(&dir).expect("Vault::open accepts the materialized seed");
    assert_eq!(vault.vault_id(), frozen_id);
    assert_eq!(vault.schema_version(), 5);

    let conn = vault.connection_ref();
    let max: i64 = conn
        .query_row("SELECT MAX(version) FROM schema_version", [], |r| r.get(0))
        .unwrap();
    assert_eq!(max, 5, "memex.db is at schema version 5");

    // Every seed row is in memex.db.
    let reference = load_on_schema(&committed_seed_sql());
    for table in app_visible_tables() {
        let cols = columns(&reference, &table);
        let mut have: HashMap<String, usize> = HashMap::new();
        for r in rows_of(conn, &table, &cols) {
            *have.entry(r).or_insert(0) += 1;
        }
        for r in rows_of(&reference, &table, &cols) {
            match have.get_mut(&r) {
                Some(n) if *n > 0 => *n -= 1,
                _ => panic!("seed row missing from {table} in memex.db: {r}"),
            }
        }
    }

    // A second root gets its own copy.
    let other = tempfile::tempdir().unwrap();
    let dir2 = materialize_seed(other.path());
    assert_eq!(dir2, other.path().join(SEED_VAULT_NAME));
    assert!(Vault::open(&dir2).is_ok());
}

#[test]
fn seed_loader_note_link_and_smart_folder_counts_equal_the_seed_sql() {
    let seed = committed_seed_sql();
    let counts = insert_counts(&seed);
    let root = tempfile::tempdir().unwrap();
    let dir = materialize_seed(root.path());
    let vault = Vault::open(&dir).unwrap();
    let conn = vault.connection_ref();
    for table in ["notes", "links", "smart_folders"] {
        let expected = *counts.get(table).unwrap_or(&0);
        assert!(expected > 0, "the seed inserts into {table}");
        assert_eq!(
            count(conn, table),
            expected,
            "{table} count in the materialized seed"
        );
    }
}

// ---------------------------------------------------------------------------
// AC3: edge rows in the committed seed
// ---------------------------------------------------------------------------

#[test]
fn committed_seed_contains_every_d10_edge_row() {
    let root = tempfile::tempdir().unwrap();
    let dir = materialize_seed(root.path());
    let vault = Vault::open(&dir).unwrap();
    assert_seed_edge_rows(vault.connection_ref(), "materialized committed seed");
}

// ---------------------------------------------------------------------------
// AC4: seed builder
// ---------------------------------------------------------------------------

fn fake_api_dir_with_stale_seed(parent: &Path) -> PathBuf {
    let dir = parent.join("api_v1");
    fs::create_dir_all(&dir).unwrap();
    fs::write(dir.join("seed_vault.sql"), "-- stale\n").unwrap();
    fs::write(dir.join("seed_manifest.json"), "{\"stale\": true}\n").unwrap();
    dir
}

fn assert_built_seed(out: &Path) {
    let sql = fs::read_to_string(out.join("seed_vault.sql")).expect("seed_vault.sql written");
    let manifest: Value = serde_json::from_slice(
        &fs::read(out.join("seed_manifest.json")).expect("seed_manifest.json written"),
    )
    .expect("seed_manifest.json is JSON");
    let id = manifest["vault_id"].as_str().expect("vault_id string");
    assert!(is_ulid(id), "built vault_id is a ULID: {id}");

    for banned in ["chunk_fts", "chunk_vec"] {
        assert!(!sql.contains(banned), "seed SQL mentions {banned}");
    }
    let allowed = app_visible_tables();
    let stmts = split_sql(&sql);
    assert!(!stmts.is_empty(), "seed SQL has statements");
    for stmt in &stmts {
        let table = insert_table(stmt)
            .unwrap_or_else(|| panic!("seed SQL may only hold INSERT statements, got: {stmt}"));
        assert!(
            allowed.contains(&table),
            "seed inserts into {table}, which is not an app-visible table"
        );
    }

    let conn = load_on_schema(&sql);
    // Loading the seed changed no schema.
    let reference = Connection::open_in_memory().unwrap();
    reference.execute_batch(&schema_sql()).unwrap();
    let ddl = |c: &Connection| -> Vec<String> {
        let mut stmt = c
            .prepare("SELECT type || ' ' || name FROM sqlite_master ORDER BY 1")
            .unwrap();
        let rows = stmt.query_map([], |r| r.get::<_, String>(0)).unwrap();
        rows.map(|r| r.unwrap()).collect()
    };
    assert_eq!(ddl(&conn), ddl(&reference), "the seed holds no DDL");
    assert_seed_edge_rows(&conn, "built seed");
}

#[test]
fn seed_builder_without_bless_writes_the_edge_rows_to_scratch_only() {
    let tmp = tempfile::tempdir().unwrap();
    let api = fake_api_dir_with_stale_seed(tmp.path());
    let scratch = tmp.path().join("scratch");
    fs::create_dir_all(&scratch).unwrap();
    let before = snapshot(&api);

    let out = run_seed_builder(&api, &scratch, false);

    assert!(
        out.starts_with(&scratch),
        "without bless the seed goes to scratch, got {}",
        out.display()
    );
    assert_eq!(
        snapshot(&api),
        before,
        "fixtures dir untouched without bless"
    );
    assert_built_seed(&out);
}

#[test]
fn seed_builder_with_bless_rewrites_the_seed_files() {
    let tmp = tempfile::tempdir().unwrap();
    let api = fake_api_dir_with_stale_seed(tmp.path());
    let scratch = tmp.path().join("scratch");
    fs::create_dir_all(&scratch).unwrap();

    let out = run_seed_builder(&api, &scratch, true);

    assert_eq!(out, api, "bless writes into the fixtures dir");
    assert_ne!(
        fs::read_to_string(api.join("seed_vault.sql")).unwrap(),
        "-- stale\n"
    );
    assert_built_seed(&api);
}

/// Entry point for blessing the committed seed (`MEMEX_BLESS=1
/// MEMEX_BLESS_SEED=1`, lead ruling on AC4); in any other run, including
/// `MEMEX_BLESS=1` alone, it proves nothing under `app/test/fixtures/` is
/// written.
#[test]
fn seed_builder_never_writes_committed_fixtures_without_bless() {
    assert_eq!(
        fs::canonicalize(api_v1_dir()).unwrap(),
        fs::canonicalize(committed_api_v1_dir()).unwrap(),
        "api_v1_dir() is app/test/fixtures/api_v1"
    );
    let scratch = tempfile::tempdir().unwrap();
    if seed_bless_requested() {
        let out = run_seed_builder(&api_v1_dir(), scratch.path(), true);
        assert_eq!(out, api_v1_dir());
        return;
    }
    let fixtures = committed_api_v1_dir().join("..");
    let before = snapshot(&fixtures);
    let out = run_seed_builder(&api_v1_dir(), scratch.path(), false);
    assert!(out.starts_with(scratch.path()));
    assert_eq!(
        snapshot(&fixtures),
        before,
        "a run without MEMEX_BLESS=1 MEMEX_BLESS_SEED=1 wrote under app/test/fixtures/"
    );
}

// ---------------------------------------------------------------------------
// AC5: row format (the Dart test in app/test/seams/api_fixtures_test.dart
// parses this exact JSON and asserts the same values)
// ---------------------------------------------------------------------------

const SHARED_INDEX_JSON: &str = r#"[
  {"method": "GET", "path": "/vaults/seed/api/v1/notes", "response": "notes_list.json", "status": 200},
  {"method": "POST", "path": "/vaults/seed/api/v1/notes", "request": "create_note.request.json",
   "response": "create_note.json", "status": 201,
   "headers": {"X-Memex-UTC-Offset": "-00:30"}, "dart_only": true}
]"#;

#[test]
fn row_loader_parses_every_row_field() {
    let tmp = tempfile::tempdir().unwrap();
    let dir = write_domain(tmp.path(), "rowsdemo", SHARED_INDEX_JSON, &[]);
    let rows = load_rows(&dir).expect("valid rows parse");
    assert_eq!(rows.len(), 2);

    let a = &rows[0];
    assert_eq!(a.method, "GET");
    assert_eq!(a.path, "/vaults/seed/api/v1/notes");
    assert_eq!(a.request, None);
    assert_eq!(a.response, "notes_list.json");
    assert_eq!(a.status, 200);
    assert!(a.headers.is_empty());
    assert!(!a.dart_only);

    let b = &rows[1];
    assert_eq!(b.method, "POST");
    assert_eq!(b.path, "/vaults/seed/api/v1/notes");
    assert_eq!(b.request.as_deref(), Some("create_note.request.json"));
    assert_eq!(b.response, "create_note.json");
    assert_eq!(b.status, 201);
    assert_eq!(
        b.headers,
        BTreeMap::from([("X-Memex-UTC-Offset".to_string(), "-00:30".to_string())])
    );
    assert!(b.dart_only);
}

#[test]
fn row_loader_rejects_a_row_missing_a_required_field_and_names_it() {
    let full =
        json!({"method": "GET", "path": "/api/v1/info", "response": "info.json", "status": 200});
    for field in ["method", "path", "response", "status"] {
        let mut broken = full.clone();
        broken.as_object_mut().unwrap().remove(field);
        let index = serde_json::to_string(&json!([full, broken])).unwrap();
        let tmp = tempfile::tempdir().unwrap();
        let dir = write_domain(tmp.path(), "rowsdemo", &index, &[]);
        let err = err_of(load_rows(&dir), field);
        assert!(err.contains("rowsdemo"), "names the domain: {err}");
        assert!(err.contains("[1]"), "names the row: {err}");
        assert!(
            err.contains(field),
            "names the missing field {field}: {err}"
        );
    }
}

#[test]
fn row_loader_rejects_malformed_index_files() {
    let tmp = tempfile::tempdir().unwrap();

    let missing = tmp.path().join("nodomain");
    fs::create_dir_all(&missing).unwrap();
    let err = err_of(load_rows(&missing), "missing index.json");
    assert!(err.contains("index.json"), "{err}");

    let dir = write_domain(tmp.path(), "notarray", "{\"method\": \"GET\"}", &[]);
    let err = err_of(load_rows(&dir), "non-array index");
    assert!(err.contains("notarray"), "{err}");

    let dir = write_domain(
        tmp.path(),
        "badstatus",
        r#"[{"method": "GET", "path": "/api/v1/info", "response": "info.json", "status": "200"}]"#,
        &[],
    );
    let err = err_of(load_rows(&dir), "string status");
    assert!(
        err.contains("badstatus") && err.contains("[0]") && err.contains("status"),
        "{err}"
    );
}

// ---------------------------------------------------------------------------
// AC6: runner check
// ---------------------------------------------------------------------------

const RUNNER_INDEX_JSON: &str = r#"[
  {"method": "GET", "path": "/vaults/seed/api/v1/things", "response": "things.json", "status": 200,
   "headers": {"X-Memex-UTC-Offset": "+05:45"}},
  {"method": "GET", "path": "/api/v1/info", "response": "info.json", "status": 200, "dart_only": true},
  {"method": "POST", "path": "/vaults/seed/api/v1/things", "request": "make_thing.request.json",
   "response": "made_thing.json", "status": 201}
]"#;

fn things_body() -> Value {
    json!({"items": [{"name": "Ada", "count": 2}], "total": 1})
}

fn runner_domain(parent: &Path, name: &str) -> PathBuf {
    write_domain(
        parent,
        name,
        RUNNER_INDEX_JSON,
        &[
            ("things.json", &canonical_json(&things_body())),
            (
                "info.json",
                "{\"server_version\": \"0.0.0\", \"api_version\": 1}\n",
            ),
            ("make_thing.request.json", "{\"name\": \"Grace\"}\n"),
            (
                "made_thing.json",
                &canonical_json(&json!({"name": "Grace"})),
            ),
        ],
    )
}

/// What the fake executor saw: method, path, headers, body.
type SeenRequest = (String, String, BTreeMap<String, String>, Option<Vec<u8>>);

#[test]
fn runner_skips_dart_only_rows_and_passes_matching_rows() {
    let tmp = tempfile::tempdir().unwrap();
    let dir = runner_domain(tmp.path(), "runnerdemo");
    let mut seen: Vec<SeenRequest> = Vec::new();

    let result = run_rows(&dir, false, |req: &FixtureRequest| {
        seen.push((
            req.method.clone(),
            req.path.clone(),
            req.headers.clone(),
            req.body.clone(),
        ));
        match (req.method.as_str(), req.path.as_str()) {
            ("GET", "/vaults/seed/api/v1/things") => FixtureResponse {
                status: 200,
                // Same JSON, other key order and whitespace.
                body: br#"{"total":1,"items":[{"count":2,"name":"Ada"}]}"#.to_vec(),
            },
            ("POST", "/vaults/seed/api/v1/things") => response(201, json!({"name": "Grace"})),
            other => panic!("executor called for {other:?}"),
        }
    });

    assert_eq!(result, Ok(()));
    assert_eq!(
        seen.len(),
        2,
        "the dart_only row never reaches the executor"
    );
    assert!(seen.iter().all(|(_, p, _, _)| p != "/api/v1/info"));

    let (m, p, h, b) = &seen[0];
    assert_eq!(
        (m.as_str(), p.as_str()),
        ("GET", "/vaults/seed/api/v1/things")
    );
    assert_eq!(
        h.get("X-Memex-UTC-Offset").map(String::as_str),
        Some("+05:45")
    );
    assert_eq!(b, &None);

    let (m, _, _, b) = &seen[1];
    assert_eq!(m, "POST");
    let body: Value =
        serde_json::from_slice(b.as_ref().expect("request file sent as body")).unwrap();
    assert_eq!(body, json!({"name": "Grace"}));
}

#[test]
fn runner_fails_on_a_different_status_value_or_extra_key_naming_the_row() {
    let cases: [(&str, u16, Value, &[&str]); 4] = [
        ("different status", 404, things_body(), &["200", "404"]),
        (
            "changed value",
            200,
            json!({"items": [{"name": "Grace", "count": 2}], "total": 1}),
            &["Ada", "Grace"],
        ),
        (
            "extra key",
            200,
            json!({"items": [{"name": "Ada", "count": 2}], "total": 1, "future_field": true}),
            &["future_field"],
        ),
        (
            "missing key",
            200,
            json!({"items": [{"name": "Ada", "count": 2}]}),
            &["total"],
        ),
    ];
    for (what, status, body, shows) in cases {
        let tmp = tempfile::tempdir().unwrap();
        let dir = write_domain(
            tmp.path(),
            "mismatchdemo",
            r#"[{"method": "GET", "path": "/vaults/seed/api/v1/things", "response": "things.json", "status": 200}]"#,
            &[("things.json", &canonical_json(&things_body()))],
        );
        let before = fs::read(dir.join("things.json")).unwrap();
        let err = err_of(
            run_rows(&dir, false, |_| response(status, body.clone())),
            what,
        );
        assert!(
            err.contains("mismatchdemo"),
            "{what}: names the domain: {err}"
        );
        assert!(
            err.contains("GET") && err.contains("/vaults/seed/api/v1/things"),
            "{what}: names the row: {err}"
        );
        for s in shows {
            assert!(
                err.contains(s),
                "{what}: shows expected vs actual ({s}): {err}"
            );
        }
        assert_eq!(
            fs::read(dir.join("things.json")).unwrap(),
            before,
            "{what}: a check run never rewrites the response file"
        );
    }
}

#[test]
fn runner_over_an_empty_domain_calls_nothing_and_passes() {
    let tmp = tempfile::tempdir().unwrap();
    let dir = write_domain(tmp.path(), "emptydemo", "[]\n", &[]);
    let mut calls = 0;
    let result = run_rows(&dir, false, |_| {
        calls += 1;
        response(200, json!({}))
    });
    assert_eq!(result, Ok(()));
    assert_eq!(calls, 0);
}

#[test]
fn runner_fails_when_a_response_file_is_missing() {
    let tmp = tempfile::tempdir().unwrap();
    let dir = write_domain(
        tmp.path(),
        "nofiledemo",
        r#"[{"method": "GET", "path": "/vaults/seed/api/v1/things", "response": "absent.json", "status": 200}]"#,
        &[],
    );
    let err = err_of(
        run_rows(&dir, false, |_| response(200, json!({}))),
        "missing response file",
    );
    assert!(
        err.contains("nofiledemo") && err.contains("absent.json"),
        "{err}"
    );
    assert!(
        !dir.join("absent.json").exists(),
        "a check run creates no file"
    );
}

#[test]
fn runner_compares_write_responses_after_normalize_volatile() {
    assert_not_in_seed(&[MINT_A, MINT_B, &TS_1.to_string(), &TS_2.to_string()]);
    let written = |id: &str, ts: i64| json!({"id": id, "title": "Fresh", "created_at": ts, "updated_at": ts, "version": 1});
    let tmp = tempfile::tempdir().unwrap();
    let dir = write_domain(
        tmp.path(),
        "writedemo",
        r#"[{"method": "POST", "path": "/vaults/seed/api/v1/notes", "response": "created.json", "status": 201}]"#,
        &[(
            "created.json",
            &canonical_json(&normalize_volatile(&written(MINT_A, TS_1))),
        )],
    );
    let result = run_rows(&dir, false, |_| response(201, written(MINT_B, TS_2)));
    assert_eq!(result, Ok(()), "a fresh id and timestamp still match");
}

// ---------------------------------------------------------------------------
// AC7: runner bless
// ---------------------------------------------------------------------------

#[test]
fn runner_bless_rewrites_a_mismatching_response_file_and_status() {
    let tmp = tempfile::tempdir().unwrap();
    let index = r#"[
  {"method": "GET", "path": "/vaults/seed/api/v1/things", "response": "things.json", "status": 200,
   "headers": {"X-Memex-UTC-Offset": "+05:45"}},
  {"method": "POST", "path": "/vaults/seed/api/v1/things", "request": "make_thing.request.json",
   "response": "made_thing.json", "status": 200},
  {"method": "GET", "path": "/api/v1/info", "response": "info.json", "status": 200, "dart_only": true,
   "headers": {"X-Memex-UTC-Offset": "-12:00"}},
  {"method": "GET", "path": "/vaults/seed/api/v1/new", "response": "new_row.json", "status": 200}
]"#;
    let dir = write_domain(
        tmp.path(),
        "blessdemo",
        index,
        &[
            ("things.json", &canonical_json(&things_body())),
            ("make_thing.request.json", "{\"name\": \"Grace\"}\n"),
            ("made_thing.json", "{\"stale\": true}\n"),
            (
                "info.json",
                "{\"server_version\": \"0.0.0\", \"api_version\": 1}\n",
            ),
        ],
    );
    let before_rows = load_rows(&dir).unwrap();
    let things_before = fs::read(dir.join("things.json")).unwrap();
    let info_before = fs::read(dir.join("info.json")).unwrap();

    let exec = |req: &FixtureRequest| match (req.method.as_str(), req.path.as_str()) {
        ("GET", "/vaults/seed/api/v1/things") => response(200, things_body()),
        ("POST", "/vaults/seed/api/v1/things") => response(201, json!({"name": "Grace", "id": 7})),
        ("GET", "/vaults/seed/api/v1/new") => response(200, json!({"fresh": true})),
        other => panic!("executor called for {other:?}"),
    };

    assert_eq!(
        run_rows(&dir, true, exec),
        Ok(()),
        "bless never fails on a mismatch"
    );

    let after_rows = load_rows(&dir).expect("blessed index.json still parses");
    assert_eq!(after_rows.len(), 4);
    assert_eq!(after_rows[1].status, 201, "mismatching status rewritten");
    assert_eq!(after_rows[1].response, "made_thing.json");
    assert_eq!(
        after_rows[1].request.as_deref(),
        Some("make_thing.request.json")
    );
    for i in [0, 2, 3] {
        assert_eq!(
            row_fields(&after_rows[i]),
            row_fields(&before_rows[i]),
            "row {i} unchanged by bless"
        );
    }

    let made = fs::read_to_string(dir.join("made_thing.json")).unwrap();
    assert_eq!(made, canonical_json(&json!({"name": "Grace", "id": 7})));
    let fresh = fs::read_to_string(dir.join("new_row.json"))
        .expect("bless creates a missing response file");
    assert_eq!(fresh, canonical_json(&json!({"fresh": true})));
    assert_eq!(fs::read(dir.join("things.json")).unwrap(), things_before);
    assert_eq!(
        fs::read(dir.join("info.json")).unwrap(),
        info_before,
        "dart_only row untouched"
    );

    assert_eq!(
        run_rows(&dir, false, exec),
        Ok(()),
        "blessed rows pass a check run"
    );
}

// ---------------------------------------------------------------------------
// AC8: normalize_volatile
// ---------------------------------------------------------------------------

fn write_response(note_id: &str, link_id: &str, ts: i64, seed_id: &str) -> Value {
    json!({
        "note": {"id": note_id, "title": "Fresh", "created_at": ts, "updated_at": ts, "version": 1},
        "links": [{"id": link_id, "from_note_id": note_id, "to_note_id": seed_id, "position": 0}],
        "ids": [note_id, link_id],
        "nested": {"deep": {"note_id": note_id}}
    })
}

#[test]
fn normalize_volatile_replaces_minted_ids_and_timestamps_with_shared_placeholders() {
    assert_not_in_seed(&[MINT_A, MINT_B, &TS_1.to_string()]);
    let (seed_id, _) = a_seed_note();
    let out = normalize_volatile(&write_response(MINT_A, MINT_B, TS_1, &seed_id));
    let text = out.to_string();
    let ts1 = TS_1.to_string();

    for gone in [MINT_A, MINT_B, ts1.as_str()] {
        assert!(!text.contains(gone), "{gone} must be replaced: {text}");
    }
    let a = &out["note"]["id"];
    assert!(a.is_string(), "{text}");
    assert_eq!(
        &out["links"][0]["from_note_id"], a,
        "same id, same placeholder"
    );
    assert_eq!(&out["ids"][0], a);
    assert_eq!(&out["nested"]["deep"]["note_id"], a);
    let b = &out["links"][0]["id"];
    assert_eq!(&out["ids"][1], b);
    assert_ne!(a, b, "different minted ids get different placeholders");
    assert_ne!(out["note"]["created_at"], json!(TS_1));
    assert_ne!(out["note"]["updated_at"], json!(TS_1));

    // Untouched alongside: the seed id and plain values.
    assert_eq!(out["links"][0]["to_note_id"], json!(seed_id));
    assert_eq!(out["note"]["title"], json!("Fresh"));
    assert_eq!(out["note"]["version"], json!(1));
    assert_eq!(out["links"][0]["position"], json!(0));
}

#[test]
fn normalize_volatile_leaves_seed_ids_and_other_values_untouched() {
    let (seed_id, seed_created_at) = a_seed_note();
    let vault_id = committed_seed_vault_id();
    let v = json!({
        "id": seed_id,
        "vault_id": vault_id,
        "name": SEED_VAULT_NAME,
        "title": "Player Loop",
        "version": 3,
        "count": 7,
        "created_at": seed_created_at,
        "updated_at": seed_created_at,
        "kind": "related",
        "nested": {"note_id": seed_id, "flags": [true, false, null], "ratio": 0.5, "empty": {}},
        "list": []
    });
    assert_eq!(normalize_volatile(&v), v);
}

#[test]
fn normalize_volatile_output_is_identical_across_runs() {
    assert_not_in_seed(&[
        MINT_A,
        MINT_B,
        MINT_C,
        MINT_D,
        &TS_1.to_string(),
        &TS_2.to_string(),
    ]);
    let (seed_id, _) = a_seed_note();
    let run1 = normalize_volatile(&write_response(MINT_A, MINT_B, TS_1, &seed_id));
    let run2 = normalize_volatile(&write_response(MINT_C, MINT_D, TS_2, &seed_id));
    assert_eq!(canonical_json(&run1), canonical_json(&run2));
    assert_eq!(
        normalize_volatile(&run1),
        run1,
        "placeholders are themselves stable"
    );
    // Same input, same output.
    assert_eq!(
        normalize_volatile(&write_response(MINT_A, MINT_B, TS_1, &seed_id)),
        run1
    );
}

// ---------------------------------------------------------------------------
// AC9: utc_offsets.json (D10a)
// ---------------------------------------------------------------------------

/// Independent reading of the D5 grammar, to check the fixture itself.
fn grammar_minutes(h: &str) -> Option<i32> {
    let re = Regex::new(r"^([+-])(\d{2}):(\d{2})$").unwrap();
    let c = re.captures(h)?;
    let (hh, mm): (i32, i32) = (c[2].parse().ok()?, c[3].parse().ok()?);
    if mm > 59 {
        return None;
    }
    let total = hh * 60 + mm;
    if total > 14 * 60 {
        return None;
    }
    Some(if &c[1] == "-" { -total } else { total })
}

#[test]
fn utc_offsets_fixture_has_valid_invalid_and_format_rows() {
    assert!(
        committed_api_v1_dir()
            .join("server/utc_offsets.json")
            .is_file(),
        "api_v1/server/utc_offsets.json exists"
    );
    let cases = load_utc_offsets();

    for (h, m) in [
        ("-00:30", -30),
        ("+14:00", 840),
        ("-12:00", -720),
        ("-14:00", -840),
        ("+00:00", 0),
        ("+05:45", 345),
    ] {
        assert_eq!(cases.valid.get(h), Some(&m), "valid {h} → {m}");
    }
    for h in ["+15:00", "+5:00", "+05:60", "+14:01", "05:30", "+0530", ""] {
        assert!(cases.invalid.iter().any(|x| x == h), "invalid {h:?} listed");
    }
    for (m, h) in [
        (-30, "-00:30"),
        (0, "+00:00"),
        (345, "+05:45"),
        (-720, "-12:00"),
    ] {
        assert_eq!(
            cases.format.get(&m).map(String::as_str),
            Some(h),
            "format {m} → {h}"
        );
    }

    // The fixture is self-consistent with the D5 grammar.
    for (h, m) in &cases.valid {
        assert_eq!(grammar_minutes(h), Some(*m), "valid row {h} → {m}");
    }
    for h in &cases.invalid {
        assert_eq!(
            grammar_minutes(h),
            None,
            "invalid row {h:?} parses under D5"
        );
        assert!(!cases.valid.contains_key(h), "{h:?} both valid and invalid");
    }
    for (m, h) in &cases.format {
        assert_eq!(grammar_minutes(h), Some(*m), "format row {m} → {h}");
    }
}

// ---------------------------------------------------------------------------
// AC10: compat/ unknown-key row
// ---------------------------------------------------------------------------

#[test]
fn compat_domain_has_one_dart_only_info_row_and_the_runner_skips_it() {
    let dir = committed_api_v1_dir().join("compat");
    let rows = load_rows(&dir).expect("compat/index.json parses");
    assert_eq!(rows.len(), 1, "compat holds exactly one row");
    let row = &rows[0];
    assert_eq!(row.method, "GET");
    assert_eq!(row.path, "/api/v1/info");
    assert_eq!(row.status, 200);
    assert!(row.dart_only, "the unknown-key row is dart_only");

    let body: Value =
        serde_json::from_slice(&fs::read(dir.join(&row.response)).expect("response file exists"))
            .expect("response is JSON");
    let obj = body.as_object().expect("response is an object");
    assert!(obj["server_version"].is_string(), "{body}");
    assert_eq!(obj["api_version"], json!(1));
    let extra: Vec<&String> = obj
        .keys()
        .filter(|k| *k != "server_version" && *k != "api_version")
        .collect();
    assert_eq!(extra.len(), 1, "exactly one unknown key: {extra:?}");

    let mut calls = 0;
    let result = run_rows(&dir, false, |_| {
        calls += 1;
        response(200, json!({}))
    });
    assert_eq!(result, Ok(()));
    assert_eq!(calls, 0, "the Rust runner never executes compat/");
}

// ---------------------------------------------------------------------------
// Contracts the support module documents (verify-mode pins)
// ---------------------------------------------------------------------------

/// Runs `f`, which must panic; returns the panic message.
fn panic_message(f: impl FnOnce()) -> String {
    match std::panic::catch_unwind(std::panic::AssertUnwindSafe(f)) {
        Ok(()) => panic!("expected a panic"),
        Err(e) => e
            .downcast_ref::<String>()
            .cloned()
            .or_else(|| e.downcast_ref::<&str>().map(|s| s.to_string()))
            .unwrap_or_default(),
    }
}

/// Names in `dir` that look like a leftover temp file of `write_atomic`.
fn temp_leftovers(dir: &Path) -> Vec<String> {
    fs::read_dir(dir)
        .unwrap()
        .map(|e| e.unwrap().file_name().to_string_lossy().into_owned())
        .filter(|n| n.contains(".tmp"))
        .collect()
}

/// File names directly in `dir`, sorted.
fn file_names(dir: &Path) -> Vec<String> {
    let mut names: Vec<String> = fs::read_dir(dir)
        .unwrap()
        .map(|e| e.unwrap().file_name().to_string_lossy().into_owned())
        .collect();
    names.sort();
    names
}

#[test]
fn seed_builder_refuses_the_committed_dir_without_both_bless_switches() {
    if seed_bless_requested() {
        // The real regeneration run; the refusal can't be observed here.
        return;
    }
    let fixtures = committed_api_v1_dir().join("..");
    let before = snapshot(&fixtures);
    // The committed dir, spelled two ways: the refusal compares real paths.
    let spellings = [api_v1_dir(), committed_api_v1_dir().join("../api_v1")];
    for dir in spellings {
        let scratch = tempfile::tempdir().unwrap();
        let msg = panic_message(|| {
            run_seed_builder(&dir, scratch.path(), true);
        });
        assert!(
            msg.contains("MEMEX_BLESS=1") && msg.contains("MEMEX_BLESS_SEED=1"),
            "the refusal names both switches: {msg:?}"
        );
        assert!(
            file_names(scratch.path()).is_empty(),
            "a refused build writes nothing to scratch either"
        );
    }
    assert_eq!(
        snapshot(&fixtures),
        before,
        "a refused seed bless wrote under app/test/fixtures/"
    );
}

/// Re-runs this test binary with `MEMEX_BLESS=1` alone, so the lead ruling on
/// AC4 is checked in every normal run, not only when someone sets the switch.
#[test]
fn memex_bless_alone_never_regenerates_the_committed_seed() {
    let tests = [
        "seed_builder_refuses_the_committed_dir_without_both_bless_switches",
        "seed_builder_never_writes_committed_fixtures_without_bless",
    ];
    let out = std::process::Command::new(std::env::current_exe().unwrap())
        .args(tests)
        .args(["--exact", "--test-threads=1"])
        .env("MEMEX_BLESS", "1")
        .env_remove("MEMEX_BLESS_SEED")
        .output()
        .expect("re-run the test binary");
    let stdout = String::from_utf8_lossy(&out.stdout);
    let stderr = String::from_utf8_lossy(&out.stderr);
    assert!(
        out.status.success(),
        "under MEMEX_BLESS=1 alone:\n{stdout}\n{stderr}"
    );
    assert!(
        stdout.contains("2 passed"),
        "both tests ran under MEMEX_BLESS=1 alone:\n{stdout}"
    );
}

#[test]
fn seed_builder_bless_replaces_the_seed_files_by_rename_and_leaves_no_temp_file() {
    let tmp = tempfile::tempdir().unwrap();
    let api = fake_api_dir_with_stale_seed(tmp.path());
    let scratch = tmp.path().join("scratch");
    fs::create_dir_all(&scratch).unwrap();
    // A hard link keeps the old inode: an in-place write would change it too,
    // a write-then-rename leaves it holding the old bytes.
    let held = tmp.path().join("held");
    fs::create_dir_all(&held).unwrap();
    fs::hard_link(api.join("seed_vault.sql"), held.join("seed_vault.sql")).unwrap();
    fs::hard_link(
        api.join("seed_manifest.json"),
        held.join("seed_manifest.json"),
    )
    .unwrap();

    run_seed_builder(&api, &scratch, true);

    assert_eq!(
        fs::read_to_string(held.join("seed_vault.sql")).unwrap(),
        "-- stale\n",
        "seed_vault.sql was rewritten in place, not renamed over"
    );
    assert_eq!(
        fs::read_to_string(held.join("seed_manifest.json")).unwrap(),
        "{\"stale\": true}\n",
        "seed_manifest.json was rewritten in place, not renamed over"
    );
    assert_ne!(
        fs::read_to_string(api.join("seed_vault.sql")).unwrap(),
        "-- stale\n"
    );
    assert_eq!(
        file_names(&api),
        vec!["seed_manifest.json", "seed_vault.sql"],
        "only the two seed files remain, no temp file"
    );
}

#[test]
fn seed_builder_without_bless_creates_a_missing_scratch_dir_with_only_the_seed_files() {
    let tmp = tempfile::tempdir().unwrap();
    let api = fake_api_dir_with_stale_seed(tmp.path());
    let scratch = tmp.path().join("not").join("yet");
    let out = run_seed_builder(&api, &scratch, false);
    assert_eq!(out, scratch);
    assert_eq!(
        file_names(&scratch),
        vec!["seed_manifest.json", "seed_vault.sql"]
    );
    let manifest: Value =
        serde_json::from_slice(&fs::read(scratch.join("seed_manifest.json")).unwrap()).unwrap();
    assert!(
        !manifest["created_at"].is_null(),
        "the manifest carries created_at: {manifest}"
    );
}

#[test]
fn runner_bless_replaces_response_and_index_files_by_rename() {
    let tmp = tempfile::tempdir().unwrap();
    let dir = write_domain(
        tmp.path(),
        "renamedemo",
        r#"[{"method": "GET", "path": "/vaults/seed/api/v1/things", "response": "things.json", "status": 200}]"#,
        &[("things.json", "{\"stale\": true}\n")],
    );
    let held = tmp.path().join("held");
    fs::create_dir_all(&held).unwrap();
    fs::hard_link(dir.join("things.json"), held.join("things.json")).unwrap();
    fs::hard_link(dir.join("index.json"), held.join("index.json")).unwrap();
    let index_before = fs::read(dir.join("index.json")).unwrap();

    let result = run_rows(&dir, true, |_| response(201, things_body()));
    assert_eq!(result, Ok(()));

    assert_eq!(
        fs::read_to_string(held.join("things.json")).unwrap(),
        "{\"stale\": true}\n",
        "the response file was rewritten in place, not renamed over"
    );
    assert_eq!(
        fs::read(held.join("index.json")).unwrap(),
        index_before,
        "index.json was rewritten in place, not renamed over"
    );
    assert_eq!(
        fs::read_to_string(dir.join("things.json")).unwrap(),
        canonical_json(&things_body())
    );
    assert_eq!(load_rows(&dir).unwrap()[0].status, 201);
    assert_eq!(
        file_names(&dir),
        vec!["index.json", "things.json"],
        "no temp file left"
    );
}

#[test]
fn runner_bless_cleans_up_its_temp_file_when_the_rename_fails() {
    let tmp = tempfile::tempdir().unwrap();
    let dir = write_domain(
        tmp.path(),
        "renamefaildemo",
        r#"[{"method": "GET", "path": "/vaults/seed/api/v1/things", "response": "blocked.json", "status": 200}]"#,
        &[],
    );
    // A non-empty directory where the response file goes: rename can't
    // replace it.
    fs::create_dir_all(dir.join("blocked.json")).unwrap();
    fs::write(dir.join("blocked.json").join("keep"), "x").unwrap();

    let msg = panic_message(|| {
        let _ = run_rows(&dir, true, |_| response(200, things_body()));
    });
    assert!(msg.contains("blocked.json"), "names the target: {msg:?}");
    assert!(
        temp_leftovers(&dir).is_empty(),
        "temp file left behind: {:?}",
        temp_leftovers(&dir)
    );
    assert_eq!(
        fs::read(dir.join("blocked.json").join("keep")).unwrap(),
        b"x"
    );
}

#[test]
fn runner_bless_keeps_every_field_of_the_other_rows_in_index_json() {
    let tmp = tempfile::tempdir().unwrap();
    let index = json!([
        {"method": "GET", "path": "/vaults/seed/api/v1/a", "response": "a.json", "status": 200,
         "headers": {"X-Memex-UTC-Offset": "+05:45", "Accept": "application/json"},
         "comment": "kept by bless", "dart_only": false},
        {"method": "GET", "path": "/vaults/seed/api/v1/b", "response": "b.json", "status": 200,
         "request": "b.request.json", "note": {"why": "nested unknown field"}},
        {"method": "GET", "path": "/api/v1/info", "response": "info.json", "status": 200,
         "dart_only": true, "extra": [1, 2, 3]}
    ]);
    let dir = write_domain(
        tmp.path(),
        "keepfields",
        &serde_json::to_string_pretty(&index).unwrap(),
        &[
            ("a.json", &canonical_json(&json!({"a": 1}))),
            ("b.json", &canonical_json(&json!({"b": 1}))),
            ("b.request.json", "{}\n"),
            ("info.json", "{}\n"),
        ],
    );
    let exec = |req: &FixtureRequest| match req.path.as_str() {
        "/vaults/seed/api/v1/a" => response(200, json!({"a": 1})),
        "/vaults/seed/api/v1/b" => response(404, json!({"b": 1})),
        other => panic!("executor called for {other}"),
    };
    assert_eq!(run_rows(&dir, true, exec), Ok(()));

    let after: Value = serde_json::from_slice(&fs::read(dir.join("index.json")).unwrap())
        .expect("blessed index.json is JSON");
    let mut expected = index.clone();
    expected[1]["status"] = json!(404);
    assert_eq!(
        after, expected,
        "only row 1's status changed; every other field of every row kept"
    );
    assert_eq!(run_rows(&dir, false, exec), Ok(()));
}

#[test]
fn runner_bless_leaves_index_json_bytes_alone_when_no_status_changed() {
    let tmp = tempfile::tempdir().unwrap();
    // Hand-written formatting that a re-serialization would change.
    let index = "[ {\"status\": 200, \"method\": \"GET\", \"path\": \"/vaults/seed/api/v1/a\", \"response\": \"a.json\"} ]";
    let dir = write_domain(
        tmp.path(),
        "untouchedindex",
        index,
        &[("a.json", "{\"stale\": 1}\n")],
    );
    assert_eq!(
        run_rows(&dir, true, |_| response(200, json!({"fresh": 1}))),
        Ok(())
    );
    assert_eq!(fs::read_to_string(dir.join("index.json")).unwrap(), index);
    assert_eq!(
        fs::read_to_string(dir.join("a.json")).unwrap(),
        canonical_json(&json!({"fresh": 1}))
    );
}

#[test]
fn runner_normalizes_the_expected_file_and_the_actual_body_before_comparing() {
    assert_not_in_seed(&[MINT_A, MINT_B, &TS_1.to_string(), &TS_2.to_string()]);
    let written = |id: &str, ts: i64| json!({"id": id, "self": format!("/vaults/seed/api/v1/notes/{id}"), "created_at": ts});
    let tmp = tempfile::tempdir().unwrap();
    // The expected file holds raw minted values, not placeholders.
    let dir = write_domain(
        tmp.path(),
        "rawexpected",
        r#"[{"method": "POST", "path": "/vaults/seed/api/v1/notes", "response": "created.json", "status": 201}]"#,
        &[("created.json", &written(MINT_A, TS_1).to_string())],
    );
    assert_eq!(
        run_rows(&dir, false, |_| response(201, written(MINT_B, TS_2))),
        Ok(()),
        "raw expected and raw actual match after normalizing both"
    );

    // A real difference beside the minted values still fails.
    let err = err_of(
        run_rows(&dir, false, |_| {
            let mut v = written(MINT_B, TS_2);
            v["extra"] = json!(true);
            response(201, v)
        }),
        "extra key beside minted values",
    );
    assert!(err.contains("extra"), "{err}");
}

#[test]
fn runner_bless_stores_the_normalized_canonical_response() {
    assert_not_in_seed(&[MINT_A, &TS_1.to_string()]);
    let tmp = tempfile::tempdir().unwrap();
    let dir = write_domain(
        tmp.path(),
        "blessnormalized",
        r#"[{"method": "POST", "path": "/vaults/seed/api/v1/notes", "response": "created.json", "status": 201}]"#,
        &[],
    );
    let actual = json!({"id": MINT_A, "created_at": TS_1, "title": "Fresh"});
    assert_eq!(
        run_rows(&dir, true, |_| response(201, actual.clone())),
        Ok(())
    );
    assert_eq!(
        fs::read_to_string(dir.join("created.json")).unwrap(),
        "{\n  \"created_at\": \"<timestamp>\",\n  \"id\": \"<id:1>\",\n  \"title\": \"Fresh\"\n}\n"
    );
}

#[test]
fn runner_compares_non_json_bodies_byte_for_byte() {
    let tmp = tempfile::tempdir().unwrap();
    let dir = write_domain(
        tmp.path(),
        "rawbody",
        r#"[{"method": "GET", "path": "/vaults/seed/api/v1/raw", "response": "raw.txt", "status": 200}]"#,
        &[("raw.txt", "not json at all\n")],
    );
    let raw = |body: &str| FixtureResponse {
        status: 200,
        body: body.as_bytes().to_vec(),
    };
    assert_eq!(run_rows(&dir, false, |_| raw("not json at all\n")), Ok(()));
    let err = err_of(
        run_rows(&dir, false, |_| raw("not json at all")),
        "a missing newline in a raw body",
    );
    assert!(
        err.contains("rawbody[0]") && err.contains("raw.txt"),
        "{err}"
    );
}

#[test]
fn runner_reports_every_failing_row_in_one_error() {
    let tmp = tempfile::tempdir().unwrap();
    let dir = write_domain(
        tmp.path(),
        "manyfail",
        r#"[
  {"method": "GET", "path": "/vaults/seed/api/v1/one", "response": "one.json", "status": 200},
  {"method": "GET", "path": "/vaults/seed/api/v1/two", "response": "two.json", "status": 200},
  {"method": "GET", "path": "/vaults/seed/api/v1/three", "response": "three.json", "status": 200}
]"#,
        &[
            ("one.json", "{\"n\": 1}\n"),
            ("two.json", "{\"n\": 2}\n"),
            ("three.json", "{\"n\": 3}\n"),
        ],
    );
    let err = err_of(
        run_rows(&dir, false, |req| match req.path.as_str() {
            "/vaults/seed/api/v1/one" => response(500, json!({"n": 1})),
            "/vaults/seed/api/v1/two" => response(200, json!({"n": 2})),
            _ => response(200, json!({"n": 33})),
        }),
        "two failing rows",
    );
    assert!(err.contains("2 fixture row(s)"), "{err}");
    assert!(
        err.contains("manyfail[0] GET /vaults/seed/api/v1/one"),
        "{err}"
    );
    assert!(
        err.contains("manyfail[2] GET /vaults/seed/api/v1/three"),
        "{err}"
    );
    assert!(
        !err.contains("manyfail[1]"),
        "a passing row is not reported: {err}"
    );
    assert!(err.contains("MEMEX_BLESS=1"), "says how to rebless: {err}");
}

#[test]
fn runner_fails_a_row_whose_request_file_is_missing_without_calling_the_executor() {
    let tmp = tempfile::tempdir().unwrap();
    let dir = write_domain(
        tmp.path(),
        "norequest",
        r#"[{"method": "POST", "path": "/vaults/seed/api/v1/things", "request": "absent.request.json", "response": "made.json", "status": 201}]"#,
        &[("made.json", "{}\n")],
    );
    for bless in [false, true] {
        let mut calls = 0;
        let err = err_of(
            run_rows(&dir, bless, |_| {
                calls += 1;
                response(201, json!({}))
            }),
            "missing request file",
        );
        assert!(
            err.contains("norequest[0]") && err.contains("absent.request.json"),
            "bless={bless}: {err}"
        );
        assert_eq!(calls, 0, "bless={bless}: executor not called");
    }
}

#[test]
fn row_loader_accepts_statuses_100_to_599_only() {
    for (status, ok) in [
        (99, false),
        (100, true),
        (599, true),
        (600, false),
        (70000, false),
        (-1, false),
    ] {
        let index = format!(
            r#"[{{"method": "GET", "path": "/api/v1/info", "response": "info.json", "status": {status}}}]"#
        );
        let tmp = tempfile::tempdir().unwrap();
        let dir = write_domain(tmp.path(), "statusrange", &index, &[]);
        match load_rows(&dir) {
            Ok(rows) => {
                assert!(ok, "status {status} must be rejected");
                assert_eq!(i64::from(rows[0].status), status);
            }
            Err(e) => {
                assert!(!ok, "status {status} must be accepted: {e}");
                assert!(
                    e.contains("statusrange[0]") && e.contains("status"),
                    "{status}: {e}"
                );
            }
        }
    }
}

#[test]
fn row_loader_rejects_optional_fields_of_the_wrong_type() {
    for (field, value) in [
        ("request", json!(1)),
        ("headers", json!(["X-Memex-UTC-Offset"])),
        ("headers", json!({"X-Memex-UTC-Offset": 30})),
        ("dart_only", json!("yes")),
        ("method", json!(1)),
    ] {
        let mut row = json!({"method": "GET", "path": "/api/v1/info", "response": "info.json", "status": 200});
        row[field] = value.clone();
        let tmp = tempfile::tempdir().unwrap();
        let dir = write_domain(
            tmp.path(),
            "wrongtype",
            &serde_json::to_string(&json!([row])).unwrap(),
            &[],
        );
        let err = err_of(load_rows(&dir), field);
        assert!(
            err.contains("wrongtype[0]") && err.contains(field),
            "{field}={value}: {err}"
        );
    }
    // Explicit nulls read as absent.
    let tmp = tempfile::tempdir().unwrap();
    let dir = write_domain(
        tmp.path(),
        "nulls",
        r#"[{"method": "GET", "path": "/api/v1/info", "response": "info.json", "status": 200, "request": null, "headers": null, "dart_only": null}]"#,
        &[],
    );
    let rows = load_rows(&dir).unwrap();
    assert_eq!(
        (
            rows[0].request.clone(),
            rows[0].headers.len(),
            rows[0].dart_only
        ),
        (None, 0, false)
    );
}

#[test]
fn normalize_volatile_replaces_minted_ids_inside_longer_strings() {
    assert_not_in_seed(&[MINT_A, MINT_B]);
    let (seed_id, _) = a_seed_note();
    let v = json!({
        "id": MINT_A,
        "self": format!("/vaults/seed/api/v1/notes/{MINT_A}"),
        "pair": format!("{MINT_A}->{MINT_B}"),
        "seed_link": format!("/vaults/seed/api/v1/notes/{seed_id}")
    });
    assert_eq!(
        normalize_volatile(&v),
        json!({
            "id": "<id:1>",
            "pair": "<id:1>-><id:2>",
            "self": "/vaults/seed/api/v1/notes/<id:1>",
            "seed_link": format!("/vaults/seed/api/v1/notes/{seed_id}")
        })
    );
}

#[test]
fn normalize_volatile_never_changes_object_keys() {
    assert_not_in_seed(&[MINT_A, MINT_B]);
    let v = json!({
        MINT_A: {"id": MINT_B},
        "created_at": {"nested_at": 5}
    });
    let out = normalize_volatile(&v);
    let keys: Vec<&String> = out.as_object().unwrap().keys().collect();
    assert_eq!(keys, vec![MINT_A, "created_at"]);
    assert_eq!(
        out[MINT_A],
        json!({"id": "<id:1>"}),
        "the key is not numbered"
    );
    assert_eq!(
        out["created_at"]
            .as_object()
            .unwrap()
            .keys()
            .collect::<Vec<_>>(),
        vec!["nested_at"]
    );
}

#[test]
fn normalize_volatile_numbers_placeholders_by_first_appearance_in_sorted_key_order() {
    assert_not_in_seed(&[MINT_A, MINT_B, MINT_C]);
    // Insertion order says c, b, a; sorted keys say a, b, c.
    let v = json!({"c": MINT_A, "b": [MINT_C, MINT_B], "a": {"z": MINT_B, "y": MINT_C}});
    assert_eq!(
        normalize_volatile(&v),
        json!({"a": {"y": "<id:1>", "z": "<id:2>"}, "b": ["<id:1>", "<id:2>"], "c": "<id:3>"})
    );
}

#[test]
fn normalize_volatile_turns_minted_timestamps_under_at_keys_into_the_timestamp_placeholder() {
    let (_, seed_created_at) = a_seed_note();
    assert_not_in_seed(&[&TS_1.to_string(), "2031-01-01T00:00:00Z"]);
    assert!(committed_seed_sql().contains("'2026-10-18'"));
    let v = json!({
        "created_at": TS_1,
        "reviewed_at": "2031-01-01T00:00:00Z",
        "seen_at": [TS_1, seed_created_at],
        "updated_at": seed_created_at,
        "day_at": "2026-10-18",
        "deleted_at": null,
        "count": TS_1,
        "label": "2031-01-01T00:00:00Z",
        "at": TS_1,
        "chat": TS_1
    });
    assert_eq!(
        normalize_volatile(&v),
        json!({
            "created_at": "<timestamp>",
            "reviewed_at": "<timestamp>",
            "seen_at": ["<timestamp>", seed_created_at],
            "updated_at": seed_created_at,
            "day_at": "2026-10-18",
            "deleted_at": null,
            "count": TS_1,
            "label": "2031-01-01T00:00:00Z",
            "at": TS_1,
            "chat": TS_1
        }),
        "only non-seed values under keys ending in _at change; the placeholder is <timestamp>"
    );
}

#[test]
fn normalize_volatile_leaves_placeholders_and_non_string_values_alone() {
    let v = json!({
        "id": "<id:7>",
        "created_at": "<timestamp>",
        "custom": "<vault_id>",
        "n": 1.5,
        "flag": true,
        "list": [null, 0, "plain"]
    });
    assert_eq!(normalize_volatile(&v), v);
}

#[test]
fn materialize_seed_indexes_the_seed_chunks_for_search() {
    let root = tempfile::tempdir().unwrap();
    let dir = materialize_seed(root.path());
    let vault = Vault::open(&dir).unwrap();
    let conn = vault.connection_ref();
    assert!(count(conn, "chunks") > 0);
    assert_eq!(
        count(conn, "chunk_fts"),
        count(conn, "chunks"),
        "one search row per seed chunk"
    );
    let hits: Vec<String> = {
        let mut stmt = conn
            .prepare(
                "SELECT n.title FROM chunk_fts f JOIN notes n ON n.id = f.note_id
                 WHERE chunk_fts MATCH 'sinks' ORDER BY n.title",
            )
            .unwrap();
        let rows = stmt.query_map([], |r| r.get::<_, String>(0)).unwrap();
        rows.map(|r| r.unwrap()).collect()
    };
    assert!(
        hits.iter().any(|t| t == "Economy Design"),
        "searching the seed finds Economy Design: {hits:?}"
    );
}
