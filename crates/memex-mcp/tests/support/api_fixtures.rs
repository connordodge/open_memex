//! Wire-contract fixture support (WI #74, rulings D10, D10a).
//!
//! Every serving WI checks its `app/test/fixtures/api_v1/<domain>/index.json`
//! rows with this module. Include it with
//!
//! ```text
//! #[path = "support/api_fixtures.rs"]
//! mod api_fixtures;
//! ```
//!
//! What it provides:
//!
//! - The frozen seed vault: `api_v1/seed_vault.sql` (one `INSERT INTO <table>`
//!   statement per line, data rows only, loaded on top of
//!   `vault_schema_v5.sql`) and `api_v1/seed_manifest.json` (`vault_id`,
//!   `created_at`). [`materialize_seed`] turns them into a vault folder named
//!   [`SEED_VAULT_NAME`]. [`run_seed_builder`] builds a new seed with
//!   memex-core functions.
//! - The row format and loader ([`FixtureRow`], [`load_rows`]), and the row
//!   runner ([`run_rows`]) that takes the request executor as a parameter.
//! - [`normalize_volatile`] for write responses and [`canonical_json`], the
//!   byte form every response file is stored in.
//! - The `api_v1/server/utc_offsets.json` loader ([`load_utc_offsets`]).
//!
//! Blessing:
//!
//! - `MEMEX_BLESS=1` rewrites mismatching fixture rows (response file and
//!   status) when the caller passes [`bless_requested`] to [`run_rows`].
//! - The committed seed is regenerated only with BOTH `MEMEX_BLESS=1` and
//!   `MEMEX_BLESS_SEED=1` ([`seed_bless_requested`]):
//!
//! ```sh
//! MEMEX_BLESS=1 MEMEX_BLESS_SEED=1 cargo test -p memex-mcp --test api_fixtures \
//!     seed_builder_never_writes_committed_fixtures_without_bless
//! ```
//!
//! Reblessing the seed changes every id in it, so every domain's rows must be
//! reblessed after it (treat it like a D10a change, owned by #74).
#![allow(dead_code)]

use std::cell::Cell;
use std::collections::{BTreeMap, BTreeSet, HashMap};
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::OnceLock;

use memex_core::caller::Caller;
use memex_core::canvas::{add_to_canvas_with_clock, create_canvas_with_clock};
use memex_core::footer::{self, ChipOrigin};
use memex_core::notes::{self, CreateNote, NoteId};
use memex_core::review::{self, ChangeEntry};
use memex_core::{excerpts, indexer, smart_folders, tags, Clock, Vault};
use regex::Regex;
use rusqlite::types::Value as SqlValue;
use rusqlite::{params, Connection};
use serde_json::{Map, Value};

/// The vault name used in every row path (`/vaults/seed/api/v1/...`).
pub const SEED_VAULT_NAME: &str = "seed";

const BLESS_ENV: &str = "MEMEX_BLESS";
const BLESS_SEED_ENV: &str = "MEMEX_BLESS_SEED";
const SEED_SQL_FILE: &str = "seed_vault.sql";
const SEED_MANIFEST_FILE: &str = "seed_manifest.json";
const INDEX_FILE: &str = "index.json";

/// `<repo>/app/test/fixtures/api_v1`.
pub fn api_v1_dir() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../../app/test/fixtures/api_v1")
}

/// `MEMEX_BLESS == "1"`: fixture rows may be rewritten.
pub fn bless_requested() -> bool {
    env_is_one(BLESS_ENV)
}

/// `MEMEX_BLESS == "1"` and `MEMEX_BLESS_SEED == "1"`: the committed seed may
/// be regenerated.
pub fn seed_bless_requested() -> bool {
    env_is_one(BLESS_ENV) && env_is_one(BLESS_SEED_ENV)
}

fn env_is_one(name: &str) -> bool {
    std::env::var(name).is_ok_and(|v| v == "1")
}

// ---------------------------------------------------------------------------
// Seed loader
// ---------------------------------------------------------------------------

/// The committed seed SQL.
pub fn seed_sql() -> String {
    read_string(&api_v1_dir().join(SEED_SQL_FILE))
}

/// The committed seed manifest (`vault_id`, `created_at`).
pub fn seed_manifest() -> Value {
    let path = api_v1_dir().join(SEED_MANIFEST_FILE);
    serde_json::from_str(&read_string(&path))
        .unwrap_or_else(|e| panic!("{} is not JSON: {e}", path.display()))
}

/// The frozen seed `vault_id`.
pub fn seed_vault_id() -> String {
    seed_manifest()["vault_id"]
        .as_str()
        .unwrap_or_else(|| panic!("{SEED_MANIFEST_FILE} has no string vault_id"))
        .to_string()
}

/// Creates `<root>/<SEED_VAULT_NAME>/`, a vault holding the committed seed:
/// `manifest.json` with the frozen `vault_id` and `memex.db` at schema version
/// 5 with every seed row (and the search index rows for the seed's chunks).
/// Returns the folder. `root` is created when missing.
pub fn materialize_seed(root: &Path) -> PathBuf {
    let dir = root.join(SEED_VAULT_NAME);
    let abs = std::path::absolute(&dir)
        .unwrap_or_else(|e| panic!("absolute path of {}: {e}", dir.display()));
    drop(
        Vault::create(&abs)
            .unwrap_or_else(|e| panic!("create seed vault at {}: {e}", abs.display())),
    );

    let manifest_path = abs.join("manifest.json");
    let mut manifest: Value = serde_json::from_str(&read_string(&manifest_path))
        .unwrap_or_else(|e| panic!("{} is not JSON: {e}", manifest_path.display()));
    let frozen = seed_manifest();
    for key in ["vault_id", "created_at"] {
        if let Some(v) = frozen.get(key) {
            manifest[key] = v.clone();
        }
    }
    let bytes = serde_json::to_vec_pretty(&manifest).expect("manifest serializes");
    fs::write(&manifest_path, bytes)
        .unwrap_or_else(|e| panic!("write {}: {e}", manifest_path.display()));

    let mut conn = Connection::open(abs.join("memex.db"))
        .unwrap_or_else(|e| panic!("open seed memex.db: {e}"));
    let tx = conn.transaction().expect("begin seed load");
    tx.pragma_update(None, "defer_foreign_keys", "ON")
        .expect("defer foreign keys");
    tx.execute_batch(&seed_sql())
        .unwrap_or_else(|e| panic!("load {SEED_SQL_FILE} into the seed vault: {e}"));
    // The seed holds no search-index rows (D10); rebuild them from `chunks`.
    tx.execute(
        "INSERT INTO chunk_fts (chunk_id, note_id, content) SELECT id, note_id, content FROM chunks",
        [],
    )
    .expect("index the seed chunks");
    tx.commit().expect("commit seed load");
    dir
}

// ---------------------------------------------------------------------------
// Seed builder
// ---------------------------------------------------------------------------

/// Builds a seed with memex-core functions and writes `seed_vault.sql` and
/// `seed_manifest.json` into `api_v1_dir` when `bless`, else into `scratch`.
/// Returns the directory it wrote. Each file is written atomically
/// (write-then-rename), so a concurrent reader sees the old or the new file.
///
/// Writing into the committed `app/test/fixtures/api_v1` additionally needs
/// [`seed_bless_requested`] (`MEMEX_BLESS=1 MEMEX_BLESS_SEED=1`); without it
/// the builder panics and writes nothing.
pub fn run_seed_builder(api_v1_dir: &Path, scratch: &Path, bless: bool) -> PathBuf {
    let target = if bless {
        if is_committed_api_v1_dir(api_v1_dir) && !seed_bless_requested() {
            panic!(
                "regenerating the committed seed needs {BLESS_ENV}=1 and {BLESS_SEED_ENV}=1 \
                 ({BLESS_ENV}=1 alone blesses fixture rows only)"
            );
        }
        api_v1_dir.to_path_buf()
    } else {
        scratch.to_path_buf()
    };
    let (sql, manifest) = build_seed();
    fs::create_dir_all(&target).unwrap_or_else(|e| panic!("create {}: {e}", target.display()));
    write_atomic(&target.join(SEED_SQL_FILE), sql.as_bytes());
    write_atomic(&target.join(SEED_MANIFEST_FILE), manifest.as_bytes());
    target
}

fn is_committed_api_v1_dir(dir: &Path) -> bool {
    match (fs::canonicalize(dir), fs::canonicalize(api_v1_dir())) {
        (Ok(a), Ok(b)) => a == b,
        _ => false,
    }
}

/// A clock that starts at a fixed instant and moves one minute per read.
struct StepClock(Cell<i64>);

impl Clock for StepClock {
    fn now_ms(&self) -> i64 {
        let now = self.0.get();
        self.0.set(now + 60_000);
        now
    }
}

/// The 120-UTF-16-unit snippet cut (`VaultDb._snippet`).
const SNIPPET_CUT: usize = 120;

/// 119 ASCII units, then a surrogate pair at units 119-120 (D10 edge row).
fn long_snippet_line() -> String {
    let lead = "Pacing is the quiet half of design: each session needs a slow stretch, \
                a sharp climb, and a short pause before the dice";
    let line = format!("{lead}\u{1F3B2} decide the next run.");
    let units: Vec<u16> = line.encode_utf16().collect();
    assert!(
        units.len() > SNIPPET_CUT
            && line.chars().count() > SNIPPET_CUT
            && (0xD800..=0xDBFF).contains(&units[SNIPPET_CUT - 1])
            && (0xDC00..=0xDFFF).contains(&units[SNIPPET_CUT]),
        "the long snippet line must put a surrogate pair at UTF-16 units 119-120"
    );
    line
}

/// Builds a fresh seed vault in a temp dir and returns `(seed SQL, manifest)`.
fn build_seed() -> (String, String) {
    let tmp = tempfile::tempdir().expect("seed temp dir");
    let root = std::path::absolute(tmp.path().join(SEED_VAULT_NAME)).expect("absolute temp path");
    let mut vault = Vault::create(&root).expect("create the seed vault");
    let clock = StepClock(Cell::new(1_760_000_000_000));
    populate(&mut vault, &clock);
    let sql = dump_seed(vault.connection_ref());
    let manifest = serde_json::json!({
        "vault_id": vault.vault_id(),
        "created_at": vault.manifest().created_at,
    });
    let manifest = format!(
        "{}\n",
        serde_json::to_string_pretty(&manifest).expect("manifest serializes")
    );
    (sql, manifest)
}

fn create(vault: &mut Vault, clock: &StepClock, title: &str, content: &str, fm: Value) -> NoteId {
    let input = CreateNote {
        title: Some(title.to_string()),
        content_md: content.to_string(),
        frontmatter: Some(fm),
    };
    notes::create_or_adopt_note(vault, input, Caller::Person, clock)
        .unwrap_or_else(|e| panic!("create note {title:?}: {e}"))
        .note
        .id
}

fn first_block_id(vault: &Vault, note_id: &NoteId) -> String {
    vault
        .connection_ref()
        .query_row(
            "SELECT block_id FROM blocks WHERE note_id = ? ORDER BY ord LIMIT 1",
            params![note_id.as_str()],
            |r| r.get(0),
        )
        .unwrap_or_else(|e| panic!("first block of {note_id}: {e}"))
}

/// The seed's content. Covers every value both languages compute (D10):
/// a heading-prefixed snippet, a long snippet with a surrogate pair at the
/// cut, a ghost link, an unreviewed and a reviewed daily note, pinned and
/// unpinned Smart Folders (one nested), tags, footer chips, an excerpt, typed
/// links and a canvas.
fn populate(vault: &mut Vault, clock: &StepClock) {
    let topic = || serde_json::json!({ "role": "topic" });
    let daily = || serde_json::json!({ "role": "daily" });

    let player_loop = create(
        vault,
        clock,
        "Player Loop",
        "# Player Loop\n\nExplore, gather, build, repeat. The loop feeds the [[Economy Design]] \
         and an idea nobody has written yet: [[Unwritten Idea]].\n",
        topic(),
    );
    let economy = create(
        vault,
        clock,
        "Economy Design",
        "Sources and sinks keep prices honest.\n\nEvery sink extends the \
         [[Player Loop~extends]].\n",
        topic(),
    );
    let pacing = create(
        vault,
        clock,
        "Pacing Notes",
        &format!(
            "{}\n\nShort runs, long arcs. See [[Player Loop|the loop]].\n",
            long_snippet_line()
        ),
        topic(),
    );
    let loose = create(
        vault,
        clock,
        "Loose Thought",
        "Maybe the map folds like paper?\n",
        serde_json::json!({}),
    );
    let reviewed_day = create(
        vault,
        clock,
        "2026-10-18",
        "Played the prototype for an hour.\n\nThe [[Player Loop]] drags after the third run.\n",
        daily(),
    );
    let unreviewed_day = create(
        vault,
        clock,
        "2026-10-19",
        "Sketched a crafting tree.\n\nPrices felt too low in town.\n",
        daily(),
    );

    for (note, tag) in [
        (&player_loop, "core"),
        (&player_loop, "loop"),
        (&loose, "idea"),
    ] {
        tags::add_tag(vault, note.as_str(), tag).expect("add tag");
    }

    // Resolve every link now that all titles exist.
    let all: Vec<(String, String)> = {
        let mut stmt = vault
            .connection_ref()
            .prepare("SELECT id, content_md FROM notes ORDER BY rowid")
            .unwrap();
        let rows = stmt.query_map([], |r| Ok((r.get(0)?, r.get(1)?))).unwrap();
        rows.map(|r| r.unwrap()).collect()
    };
    for (id, content) in &all {
        indexer::reindex_note(vault.connection_mut(), id, content, None).expect("reindex note");
    }

    // Footer chips: an excerpt (origin excerpt) and a person chip.
    let block = first_block_id(vault, &unreviewed_day);
    excerpts::add_excerpt(
        vault,
        &economy,
        "2026-10-19",
        &[block],
        Caller::Person,
        None,
    )
    .expect("excerpt into Economy Design");
    footer::set_chip(vault, &reviewed_day, &economy, ChipOrigin::Person, None)
        .expect("person footer chip");

    // Smart Folders: a pinned root (person), a nested unpinned child and an
    // unpinned root (agent).
    let design = smart_folders::create_folder(vault, "Design", None, Caller::Person, clock)
        .expect("create Design");
    let systems =
        smart_folders::create_folder(vault, "Systems", Some(&design.id), Caller::Agent, clock)
            .expect("create Systems");
    smart_folders::create_folder(vault, "Inbox", None, Caller::Agent, clock).expect("create Inbox");
    smart_folders::add_member(
        vault,
        &design.id,
        player_loop.as_str(),
        None,
        Caller::Person,
        None,
    )
    .expect("Player Loop in Design");
    smart_folders::add_member(
        vault,
        &systems.id,
        economy.as_str(),
        None,
        Caller::Agent,
        None,
    )
    .expect("Economy Design in Systems");
    smart_folders::add_member(
        vault,
        &systems.id,
        pacing.as_str(),
        Some(false),
        Caller::Person,
        None,
    )
    .expect("Pacing Notes in Systems");

    // A canvas with two notes on it.
    let canvas = create_canvas_with_clock(vault, "Prototype Map", clock).expect("create canvas");
    add_to_canvas_with_clock(vault, &canvas.id, player_loop.as_str(), 0.0, 0.0, clock)
        .expect("place Player Loop");
    add_to_canvas_with_clock(vault, &canvas.id, economy.as_str(), 240.5, 120.0, clock)
        .expect("place Economy Design");

    // One reviewed day; 2026-10-19 stays unreviewed.
    let version: i64 = vault
        .connection_ref()
        .query_row(
            "SELECT content_version FROM day_reviews WHERE note_id = ?",
            params![reviewed_day.as_str()],
            |r| r.get(0),
        )
        .expect("day_reviews row for 2026-10-18");
    let changes = [
        ChangeEntry {
            note_id: reviewed_day.as_str().to_string(),
            bullets: vec!["Filed the prototype notes".to_string()],
        },
        ChangeEntry {
            note_id: economy.as_str().to_string(),
            bullets: vec!["Linked sinks to the player loop".to_string()],
        },
    ];
    review::mark_day_reviewed(vault, "2026-10-18", version, &changes, clock)
        .expect("mark 2026-10-18 reviewed");
}

/// Tables in insertion order (parents before children). Tables not listed
/// here are dumped after these, by name.
const TABLE_ORDER: &[&str] = &[
    "notes",
    "tags",
    "links",
    "chunks",
    "blocks",
    "day_reviews",
    "day_review_blocks",
    "footer_chips",
    "agent_changes",
    "smart_folders",
    "smart_folder_members",
    "canvases",
    "canvas_nodes",
    "pending_index",
    "notes_dedup_log",
];

/// Tables whose rows `vault_schema_v5.sql` already carries.
const SCHEMA_DATA_TABLES: &[&str] = &["schema_version", "vault_settings"];

/// The seed's data rows as SQL: one `INSERT INTO <table>` per line, rows in
/// rowid order, no DDL and nothing from the search-index tables.
fn dump_seed(conn: &Connection) -> String {
    let mut tables: Vec<String> = {
        let mut stmt = conn
            .prepare(
                "SELECT name FROM sqlite_master
                 WHERE type = 'table'
                   AND sql IS NOT NULL
                   AND sql NOT LIKE 'CREATE VIRTUAL TABLE%'
                   AND name NOT LIKE 'sqlite~_%' ESCAPE '~'
                   AND name NOT LIKE 'chunk~_fts%' ESCAPE '~'
                   AND name NOT LIKE 'chunk~_vec%' ESCAPE '~'
                 ORDER BY name",
            )
            .unwrap();
        let rows = stmt.query_map([], |r| r.get::<_, String>(0)).unwrap();
        rows.map(|r| r.unwrap())
            .filter(|t| !SCHEMA_DATA_TABLES.contains(&t.as_str()))
            .collect()
    };
    let rank = |t: &str| {
        TABLE_ORDER
            .iter()
            .position(|x| *x == t)
            .unwrap_or(TABLE_ORDER.len())
    };
    tables.sort_by(|a, b| rank(a).cmp(&rank(b)).then_with(|| a.cmp(b)));

    let mut out = String::new();
    out.push_str("-- Frozen seed vault (WI #74, D10): data rows on top of vault_schema_v5.sql.\n");
    out.push_str(
        "-- Generated by crates/memex-mcp/tests/support/api_fixtures.rs. Do not edit.\n\
         -- Regenerate (rewrites every id; rebless every domain after it):\n\
         --   MEMEX_BLESS=1 MEMEX_BLESS_SEED=1 cargo test -p memex-mcp --test api_fixtures \
         seed_builder_never_writes_committed_fixtures_without_bless\n\n",
    );
    for table in tables {
        let cols: Vec<String> = {
            let mut stmt = conn
                .prepare("SELECT name FROM pragma_table_info(?1) ORDER BY cid")
                .unwrap();
            let rows = stmt.query_map([&table], |r| r.get::<_, String>(0)).unwrap();
            rows.map(|r| r.unwrap()).collect()
        };
        let list = cols
            .iter()
            .map(|c| format!("\"{c}\""))
            .collect::<Vec<_>>()
            .join(", ");
        let mut stmt = conn
            .prepare(&format!("SELECT {list} FROM \"{table}\" ORDER BY rowid"))
            .unwrap();
        let n = cols.len();
        let rows = stmt
            .query_map([], |r| {
                (0..n)
                    .map(|i| r.get::<_, SqlValue>(i))
                    .collect::<rusqlite::Result<Vec<_>>>()
            })
            .unwrap();
        for row in rows {
            let values = row
                .unwrap()
                .iter()
                .map(sql_literal)
                .collect::<Vec<_>>()
                .join(", ");
            out.push_str(&format!(
                "INSERT INTO {table} ({}) VALUES ({values});\n",
                cols.join(", ")
            ));
        }
    }
    out
}

/// A SQL literal for `v` that fits on one line: control characters in text
/// become `char(N)` terms joined with `||`.
fn sql_literal(v: &SqlValue) -> String {
    match v {
        SqlValue::Null => "NULL".to_string(),
        SqlValue::Integer(i) => i.to_string(),
        SqlValue::Real(f) => format!("{f:?}"),
        SqlValue::Blob(b) => {
            let hex: String = b.iter().map(|x| format!("{x:02X}")).collect();
            format!("X'{hex}'")
        }
        SqlValue::Text(s) => {
            let mut parts: Vec<String> = Vec::new();
            let mut cur = String::new();
            for c in s.chars() {
                if c.is_control() {
                    if !cur.is_empty() {
                        parts.push(format!("'{}'", cur.replace('\'', "''")));
                        cur.clear();
                    }
                    parts.push(format!("char({})", c as u32));
                } else {
                    cur.push(c);
                }
            }
            if !cur.is_empty() || parts.is_empty() {
                parts.push(format!("'{}'", cur.replace('\'', "''")));
            }
            parts.join(" || ")
        }
    }
}

// ---------------------------------------------------------------------------
// Rows
// ---------------------------------------------------------------------------

/// One row of `<domain>/index.json`.
///
/// ```json
/// {"method": "POST", "path": "/vaults/seed/api/v1/notes",
///  "request": "create_note.request.json", "response": "create_note.json",
///  "status": 201, "headers": {"X-Memex-UTC-Offset": "-00:30"}, "dart_only": false}
/// ```
///
/// `method`, `path`, `response` and `status` are required. `request` names a
/// file in the domain folder sent as the body; `headers` are request headers;
/// a `dart_only` row is skipped by the Rust runner.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FixtureRow {
    pub method: String,
    pub path: String,
    pub request: Option<String>,
    pub response: String,
    pub status: u16,
    pub headers: BTreeMap<String, String>,
    pub dart_only: bool,
}

/// What the runner hands the executor for one row.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FixtureRequest {
    pub method: String,
    pub path: String,
    pub headers: BTreeMap<String, String>,
    /// The request file's bytes, when the row names one.
    pub body: Option<Vec<u8>>,
}

/// What the executor returns for one row.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FixtureResponse {
    pub status: u16,
    pub body: Vec<u8>,
}

fn domain_name(domain_dir: &Path) -> String {
    domain_dir
        .file_name()
        .map(|n| n.to_string_lossy().into_owned())
        .unwrap_or_else(|| domain_dir.display().to_string())
}

fn read_index(domain_dir: &Path) -> Result<Vec<Value>, String> {
    let domain = domain_name(domain_dir);
    let path = domain_dir.join(INDEX_FILE);
    let raw = fs::read_to_string(&path)
        .map_err(|e| format!("{domain}: cannot read {}: {e}", path.display()))?;
    let v: Value = serde_json::from_str(&raw)
        .map_err(|e| format!("{domain}: {INDEX_FILE} is not JSON: {e}"))?;
    match v {
        Value::Array(rows) => Ok(rows),
        _ => Err(format!(
            "{domain}: {INDEX_FILE} must be a JSON array of rows"
        )),
    }
}

fn parse_row(domain: &str, i: usize, v: &Value) -> Result<FixtureRow, String> {
    let name = format!("{domain}[{i}]");
    let obj = v
        .as_object()
        .ok_or_else(|| format!("{name}: a row must be a JSON object"))?;
    let required_str = |field: &str| -> Result<String, String> {
        match obj.get(field) {
            None | Some(Value::Null) => Err(format!("{name}: missing required field \"{field}\"")),
            Some(Value::String(s)) => Ok(s.clone()),
            Some(_) => Err(format!("{name}: field \"{field}\" must be a string")),
        }
    };
    let method = required_str("method")?;
    let path = required_str("path")?;
    let response = required_str("response")?;
    let status = match obj.get("status") {
        None | Some(Value::Null) => {
            return Err(format!("{name}: missing required field \"status\""))
        }
        Some(Value::Number(n)) => n
            .as_u64()
            .and_then(|n| u16::try_from(n).ok())
            .filter(|n| (100..=599).contains(n))
            .ok_or_else(|| format!("{name}: field \"status\" must be an HTTP status, got {n}"))?,
        Some(other) => {
            return Err(format!(
                "{name}: field \"status\" must be an integer, got {other}"
            ))
        }
    };
    let request = match obj.get("request") {
        None | Some(Value::Null) => None,
        Some(Value::String(s)) => Some(s.clone()),
        Some(_) => return Err(format!("{name}: field \"request\" must be a string")),
    };
    let mut headers = BTreeMap::new();
    match obj.get("headers") {
        None | Some(Value::Null) => {}
        Some(Value::Object(h)) => {
            for (k, v) in h {
                let v = v.as_str().ok_or_else(|| {
                    format!("{name}: field \"headers\" value for {k:?} must be a string")
                })?;
                headers.insert(k.clone(), v.to_string());
            }
        }
        Some(_) => return Err(format!("{name}: field \"headers\" must be an object")),
    }
    let dart_only = match obj.get("dart_only") {
        None | Some(Value::Null) => false,
        Some(Value::Bool(b)) => *b,
        Some(_) => return Err(format!("{name}: field \"dart_only\" must be a boolean")),
    };
    Ok(FixtureRow {
        method,
        path,
        request,
        response,
        status,
        headers,
        dart_only,
    })
}

/// Parses `<domain_dir>/index.json`. Errors name the row as
/// `<domain>[<zero-based index>]` and the field.
pub fn load_rows(domain_dir: &Path) -> Result<Vec<FixtureRow>, String> {
    let domain = domain_name(domain_dir);
    read_index(domain_dir)?
        .iter()
        .enumerate()
        .map(|(i, v)| parse_row(&domain, i, v))
        .collect()
}

/// The bytes a response is compared and stored as: [`canonical_json`] of the
/// normalized JSON, or the raw bytes when they are not JSON.
fn comparable(bytes: &[u8]) -> Vec<u8> {
    match serde_json::from_slice::<Value>(bytes) {
        Ok(v) => canonical_json(&normalize_volatile(&v)).into_bytes(),
        Err(_) => bytes.to_vec(),
    }
}

/// Runs every row of `domain_dir` that is not `dart_only` through `exec` and
/// compares the status and the canonical, normalized response bytes with the
/// row. A check run (`bless == false`) fails naming each mismatching row
/// (`<domain>[<i>] <METHOD> <path>`) with expected vs actual and never writes
/// a file. A bless run rewrites a mismatching (or missing) response file and,
/// when the status differs, that row's `status` in `index.json`, leaving the
/// other rows as they were.
pub fn run_rows(
    domain_dir: &Path,
    bless: bool,
    mut exec: impl FnMut(&FixtureRequest) -> FixtureResponse,
) -> Result<(), String> {
    let domain = domain_name(domain_dir);
    let rows = load_rows(domain_dir)?;
    let mut failures: Vec<String> = Vec::new();
    let mut new_statuses: BTreeMap<usize, u16> = BTreeMap::new();

    for (i, row) in rows.iter().enumerate() {
        if row.dart_only {
            continue;
        }
        let name = format!("{domain}[{i}] {} {}", row.method, row.path);
        let body = match &row.request {
            None => None,
            Some(file) => match fs::read(domain_dir.join(file)) {
                Ok(b) => Some(b),
                Err(e) => {
                    failures.push(format!("{name}: cannot read request file {file}: {e}"));
                    continue;
                }
            },
        };
        let response_path = domain_dir.join(&row.response);
        let expected = match fs::read(&response_path) {
            Ok(b) => Some(b),
            Err(_) if bless => None,
            Err(e) => {
                failures.push(format!(
                    "{name}: cannot read response file {}: {e}",
                    row.response
                ));
                continue;
            }
        };

        let request = FixtureRequest {
            method: row.method.clone(),
            path: row.path.clone(),
            headers: row.headers.clone(),
            body,
        };
        let actual = exec(&request);
        let actual_bytes = comparable(&actual.body);
        let body_matches = expected
            .as_deref()
            .is_some_and(|e| comparable(e) == actual_bytes);
        let status_matches = actual.status == row.status;

        if bless {
            if !body_matches {
                write_atomic(&response_path, &actual_bytes);
            }
            if !status_matches {
                new_statuses.insert(i, actual.status);
            }
            continue;
        }
        if !status_matches {
            failures.push(format!(
                "{name}: status differs\n  expected: {}\n  actual:   {}",
                row.status, actual.status
            ));
        }
        if !body_matches {
            let expected = comparable(expected.as_deref().unwrap_or_default());
            failures.push(format!(
                "{name}: response differs from {}\n--- expected\n{}\n--- actual\n{}",
                row.response,
                String::from_utf8_lossy(&expected),
                String::from_utf8_lossy(&actual_bytes)
            ));
        }
    }

    if !new_statuses.is_empty() {
        let mut index = read_index(domain_dir)?;
        for (i, status) in &new_statuses {
            if let Some(obj) = index[*i].as_object_mut() {
                obj.insert("status".to_string(), Value::from(*status));
            }
        }
        let text = format!(
            "{}\n",
            serde_json::to_string_pretty(&Value::Array(index)).expect("index serializes")
        );
        write_atomic(&domain_dir.join(INDEX_FILE), text.as_bytes());
    }

    if failures.is_empty() {
        Ok(())
    } else {
        Err(format!(
            "{} fixture row(s) failed in {domain} (rebless with {BLESS_ENV}=1):\n{}",
            failures.len(),
            failures.join("\n")
        ))
    }
}

// ---------------------------------------------------------------------------
// JSON
// ---------------------------------------------------------------------------

fn sorted(v: &Value) -> Value {
    match v {
        Value::Object(m) => {
            let mut keys: Vec<&String> = m.keys().collect();
            keys.sort();
            let mut out = Map::new();
            for k in keys {
                out.insert(k.clone(), sorted(&m[k]));
            }
            Value::Object(out)
        }
        Value::Array(a) => Value::Array(a.iter().map(sorted).collect()),
        other => other.clone(),
    }
}

/// The stored byte form of a JSON response: keys sorted at every level,
/// two-space pretty printing, one trailing newline.
pub fn canonical_json(v: &Value) -> String {
    format!(
        "{}\n",
        serde_json::to_string_pretty(&sorted(v)).expect("JSON serializes")
    )
}

/// The values the committed seed holds: every ULID-shaped token and every
/// integer literal in `seed_vault.sql`, plus the manifest's values.
struct SeedValues {
    text: String,
    ulids: BTreeSet<String>,
    integers: BTreeSet<i64>,
}

fn ulid_re() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| Regex::new(r"\b[0-7][0-9A-HJKMNP-TV-Z]{25}\b").unwrap())
}

fn placeholder_re() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| Regex::new(r"^<[a-z_]+(:\d+)?>$").unwrap())
}

fn seed_values() -> &'static SeedValues {
    static SEED: OnceLock<SeedValues> = OnceLock::new();
    SEED.get_or_init(|| {
        let mut text = seed_sql();
        text.push('\n');
        text.push_str(&read_string(&api_v1_dir().join(SEED_MANIFEST_FILE)));
        let ulids = ulid_re()
            .find_iter(&text)
            .map(|m| m.as_str().to_string())
            .collect();
        let integers = Regex::new(r"-?\b\d+\b")
            .unwrap()
            .find_iter(&text)
            .filter_map(|m| m.as_str().parse().ok())
            .collect();
        SeedValues {
            text,
            ulids,
            integers,
        }
    })
}

const ID_PLACEHOLDER: &str = "id";
const TIMESTAMP_PLACEHOLDER: &str = "<timestamp>";

/// Replaces the values a write mints with stable placeholders, against the
/// committed seed:
///
/// - a ULID (a whole string, or a ULID-shaped token inside a longer string)
///   that the seed does not hold becomes `<id:N>`, numbered by first
///   appearance (object keys visited in sorted order), so the same minted id
///   gets the same placeholder everywhere in the value;
/// - a number or string under a key ending in `_at` that the seed does not
///   hold becomes `"<timestamp>"`.
///
/// Seed ids, seed timestamps, object keys and every other value are left
/// as they are, and placeholders are themselves left alone, so the function
/// is idempotent and its output is the same across runs.
pub fn normalize_volatile(v: &Value) -> Value {
    let mut ids: HashMap<String, String> = HashMap::new();
    normalize_value(v, None, seed_values(), &mut ids)
}

fn normalize_value(
    v: &Value,
    key: Option<&str>,
    seed: &SeedValues,
    ids: &mut HashMap<String, String>,
) -> Value {
    let is_time_key = key.is_some_and(|k| k.ends_with("_at"));
    match v {
        Value::Object(m) => {
            let mut keys: Vec<&String> = m.keys().collect();
            keys.sort();
            let mut out = Map::new();
            for k in keys {
                out.insert(k.clone(), normalize_value(&m[k], Some(k), seed, ids));
            }
            Value::Object(out)
        }
        Value::Array(a) => Value::Array(
            a.iter()
                .map(|x| normalize_value(x, key, seed, ids))
                .collect(),
        ),
        Value::Number(n) if is_time_key => match n.as_i64() {
            Some(i) if seed.integers.contains(&i) => v.clone(),
            _ => Value::String(TIMESTAMP_PLACEHOLDER.to_string()),
        },
        Value::String(s) if placeholder_re().is_match(s) => v.clone(),
        Value::String(s) => {
            let replaced = ulid_re().replace_all(s, |c: &regex::Captures| {
                let token = &c[0];
                if seed.ulids.contains(token) {
                    return token.to_string();
                }
                let next = ids.len() + 1;
                ids.entry(token.to_string())
                    .or_insert_with(|| format!("<{ID_PLACEHOLDER}:{next}>"))
                    .clone()
            });
            if is_time_key && replaced == *s && !seed.text.contains(s.as_str()) {
                // A minted string timestamp (e.g. ISO time) under an `_at` key.
                return Value::String(TIMESTAMP_PLACEHOLDER.to_string());
            }
            Value::String(replaced.into_owned())
        }
        other => other.clone(),
    }
}

// ---------------------------------------------------------------------------
// utc_offsets.json (D10a)
// ---------------------------------------------------------------------------

/// The `X-Memex-UTC-Offset` cases of `api_v1/server/utc_offsets.json`:
/// `valid` header → signed minutes, `invalid` headers, and `format` signed
/// minutes → header.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct UtcOffsetCases {
    pub valid: BTreeMap<String, i32>,
    pub invalid: Vec<String>,
    pub format: BTreeMap<i32, String>,
}

/// Parses `api_v1/server/utc_offsets.json`. Its shape:
///
/// ```json
/// {"valid": [{"header": "-00:30", "minutes": -30}],
///  "invalid": ["+15:00"],
///  "format": [{"minutes": -30, "header": "-00:30"}]}
/// ```
pub fn load_utc_offsets() -> UtcOffsetCases {
    let path = api_v1_dir().join("server/utc_offsets.json");
    let v: Value = serde_json::from_str(&read_string(&path))
        .unwrap_or_else(|e| panic!("{} is not JSON: {e}", path.display()));
    let pairs = |set: &str| -> Vec<(String, i32)> {
        v[set]
            .as_array()
            .unwrap_or_else(|| panic!("utc_offsets.json: {set:?} must be an array"))
            .iter()
            .enumerate()
            .map(|(i, row)| {
                let header = row["header"]
                    .as_str()
                    .unwrap_or_else(|| panic!("utc_offsets.json {set}[{i}]: string \"header\""));
                let minutes = row["minutes"]
                    .as_i64()
                    .and_then(|m| i32::try_from(m).ok())
                    .unwrap_or_else(|| panic!("utc_offsets.json {set}[{i}]: integer \"minutes\""));
                (header.to_string(), minutes)
            })
            .collect()
    };
    let invalid = v["invalid"]
        .as_array()
        .unwrap_or_else(|| panic!("utc_offsets.json: \"invalid\" must be an array"))
        .iter()
        .enumerate()
        .map(|(i, h)| {
            h.as_str()
                .unwrap_or_else(|| panic!("utc_offsets.json invalid[{i}]: a string"))
                .to_string()
        })
        .collect();
    UtcOffsetCases {
        valid: pairs("valid").into_iter().collect(),
        invalid,
        format: pairs("format").into_iter().map(|(h, m)| (m, h)).collect(),
    }
}

// ---------------------------------------------------------------------------
// Files
// ---------------------------------------------------------------------------

fn read_string(path: &Path) -> String {
    fs::read_to_string(path).unwrap_or_else(|e| panic!("read {}: {e}", path.display()))
}

/// Writes `bytes` to a temp file next to `path`, then renames it over `path`.
fn write_atomic(path: &Path, bytes: &[u8]) {
    let dir = path
        .parent()
        .unwrap_or_else(|| panic!("{} has no parent", path.display()));
    let name = path
        .file_name()
        .map(|n| n.to_string_lossy().into_owned())
        .unwrap_or_default();
    static SEQ: AtomicUsize = AtomicUsize::new(0);
    let seq = SEQ.fetch_add(1, Ordering::Relaxed);
    let tmp = dir.join(format!(".{name}.tmp-{}-{seq}", std::process::id()));
    fs::write(&tmp, bytes).unwrap_or_else(|e| panic!("write {}: {e}", tmp.display()));
    fs::rename(&tmp, path).unwrap_or_else(|e| {
        let _ = fs::remove_file(&tmp);
        panic!("rename {} to {}: {e}", tmp.display(), path.display())
    });
}
