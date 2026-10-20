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
//!   [`seed_summary`] is the structural form a seed-drift check compares.
//! - The row format and loader ([`FixtureRow`], [`load_rows`]), and the row
//!   runner ([`run_rows`]) that takes the request executor as a parameter.
//!   [`all_domain_dirs`] and [`check_domain_files`] find every domain and
//!   check the files its rows name; [`parity_index_path`] is the shared row
//!   text of the Rust/Dart parse-parity check.
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

/// `VaultDb._snippet` keeps a first line of at most 120 UTF-16 units whole
/// and cuts a longer one to its first 117 units (`substring(0, 117)`).
const SNIPPET_MAX: usize = 120;
const SNIPPET_CUT: usize = 117;

/// 116 ASCII units, then a surrogate pair at units 116-117 that straddles the
/// 117-unit cut, in a line longer than 120 units (D10 edge row).
fn long_snippet_line() -> String {
    let lead = "Pacing is the quiet half of design: each session needs a slow stretch, \
                a sharp climb, and a short pause before a die";
    let line = format!("{lead}\u{1F3B2} decides the next run.");
    let units: Vec<u16> = line.encode_utf16().collect();
    assert!(
        units.len() > SNIPPET_MAX
            && line.chars().count() > SNIPPET_MAX
            && (0xD800..=0xDBFF).contains(&units[SNIPPET_CUT - 1])
            && (0xDC00..=0xDFFF).contains(&units[SNIPPET_CUT]),
        "the long snippet line must put a surrogate pair at UTF-16 units 116-117"
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
    // Fixture rows pin the frozen `vault_id` (and `created_at`), and no seed
    // row holds either, so a rebuild keeps the committed values. A freshly
    // minted pair is used only when there is no committed manifest yet.
    let committed = fs::read_to_string(api_v1_dir().join(SEED_MANIFEST_FILE))
        .ok()
        .and_then(|raw| serde_json::from_str::<Value>(&raw).ok());
    let frozen = |key: &str| committed.as_ref().and_then(|m| m.get(key)).cloned();
    let manifest = serde_json::json!({
        "vault_id": frozen("vault_id")
            .filter(Value::is_string)
            .unwrap_or_else(|| Value::from(vault.vault_id())),
        "created_at": frozen("created_at")
            .filter(Value::is_i64)
            .unwrap_or_else(|| Value::from(vault.manifest().created_at)),
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
/// 117-unit cut, a ghost link, daily notes in every review state (reviewed
/// 2026-10-18, unreviewed 2026-10-19, changed since review 2026-10-17, and
/// 2026-10-15 as a pre-V5 daily: no `day_reviews` row, no `blocks` rows, no
/// topics marker), a daily note whose first block
/// spans two lines (2026-10-16), a note with invalid-JSON frontmatter
/// ("Broken Frontmatter"), pinned and unpinned Smart Folders (one nested),
/// tags, footer chips, an excerpt, typed links and a canvas.
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
    // Reviewed below, then edited by the person: changed since review.
    let changed_day = create(
        vault,
        clock,
        "2026-10-17",
        "Tuned the shop prices.\n",
        daily(),
    );
    // The first block is one paragraph over two lines, so the daily preview
    // (the first block up to its first newline) cuts it.
    create(
        vault,
        clock,
        "2026-10-16",
        "Morning playtest with the new crafting tree\nand two fresh players.\n\nNo crashes.\n",
        daily(),
    );
    // Becomes a pre-V5 daily note below.
    let rowless_day = create(
        vault,
        clock,
        "2026-10-15",
        "Read about loot tables.\n",
        daily(),
    );
    // Gets invalid-JSON frontmatter below.
    let broken = create(
        vault,
        clock,
        "Broken Frontmatter",
        "Its frontmatter is not JSON, so every reader treats it as role-less.\n",
        serde_json::json!({}),
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

    // 2026-10-17: reviewed, then the person edits its person section, so
    // `content_version` moves past `reviewed_content_version`.
    review::mark_day_reviewed(
        vault,
        "2026-10-17",
        content_version(vault, &changed_day),
        &[ChangeEntry {
            note_id: changed_day.as_str().to_string(),
            bullets: vec!["Noted the price tuning".to_string()],
        }],
        clock,
    )
    .expect("mark 2026-10-17 reviewed");
    let current = notes::get_note(vault, &changed_day).expect("read 2026-10-17");
    let edited = notes::update_note(
        vault,
        &changed_day,
        current.version,
        notes::UpdateNote {
            content_md: Some("Tuned the shop prices.\n\nThen undid half of it.\n".to_string()),
            ..Default::default()
        },
    )
    .expect("edit 2026-10-17 after its review");
    indexer::reindex_note(
        vault.connection_mut(),
        edited.id.as_str(),
        &edited.content_md,
        None,
    )
    .expect("reindex 2026-10-17");

    // A daily note written before V5: no `day_reviews` row, no `blocks` rows
    // and no topics marker in its body, and every reader must treat it as
    // unreviewed with an empty preview. memex-core cannot write that state:
    // the daily write hook (`daily::sync_daily_note`) writes the blocks, the
    // `day_reviews` row and the marker-bearing body in one transaction, and V5
    // backfills nothing. So it is made with raw SQL, and the chunks are
    // rebuilt from the marker-free body as `reindex_note` does for any body.
    let pre_v5_body = "Read about loot tables.\n";
    {
        let conn = vault.connection_ref();
        for (sql, what) in [
            (
                "DELETE FROM day_reviews WHERE note_id = ?",
                "day_reviews row",
            ),
            ("DELETE FROM blocks WHERE note_id = ?", "blocks rows"),
        ] {
            conn.execute(sql, params![rowless_day.as_str()])
                .unwrap_or_else(|e| panic!("drop the {what} of 2026-10-15: {e}"));
        }
        conn.execute(
            "UPDATE notes SET content_md = ? WHERE id = ?",
            params![pre_v5_body, rowless_day.as_str()],
        )
        .expect("write the marker-free body of 2026-10-15");
    }
    indexer::reindex_note(
        vault.connection_mut(),
        rowless_day.as_str(),
        pre_v5_body,
        None,
    )
    .expect("reindex 2026-10-15");

    // memex-core only stores frontmatter it serialized itself, so it cannot
    // write invalid JSON; the json_valid guards in the app's reads
    // (daily_reads.dart, topics_reads.dart, graph_reads.dart) and in core
    // need a row that has it, made with raw SQL.
    vault
        .connection_ref()
        .execute(
            "UPDATE notes SET frontmatter = '{\"role\": \"topic\"' WHERE id = ?",
            params![broken.as_str()],
        )
        .expect("break the frontmatter of Broken Frontmatter");
}

fn content_version(vault: &Vault, note_id: &NoteId) -> i64 {
    vault
        .connection_ref()
        .query_row(
            "SELECT content_version FROM day_reviews WHERE note_id = ?",
            params![note_id.as_str()],
            |r| r.get(0),
        )
        .unwrap_or_else(|e| panic!("day_reviews row of {note_id}: {e}"))
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
    let mut out = String::new();
    out.push_str("-- Frozen seed vault (WI #74, D10): data rows on top of vault_schema_v5.sql.\n");
    out.push_str(
        "-- Generated by crates/memex-mcp/tests/support/api_fixtures.rs. Do not edit.\n\
         -- Regenerate (rewrites every id; rebless every domain after it):\n\
         --   MEMEX_BLESS=1 MEMEX_BLESS_SEED=1 cargo test -p memex-mcp --test api_fixtures \
         seed_builder_never_writes_committed_fixtures_without_bless\n\n",
    );
    for table in seed_tables(conn) {
        let cols = table_columns(conn, &table);
        for row in table_rows(conn, &table, &cols) {
            let values = row.iter().map(sql_literal).collect::<Vec<_>>().join(", ");
            out.push_str(&format!(
                "INSERT INTO {table} ({}) VALUES ({values});\n",
                cols.join(", ")
            ));
        }
    }
    out
}

/// The data tables a seed holds, parents before children ([`TABLE_ORDER`],
/// then the rest by name): every ordinary table except the search-index
/// tables and the tables `vault_schema_v5.sql` already fills.
fn seed_tables(conn: &Connection) -> Vec<String> {
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
    tables
}

fn table_columns(conn: &Connection, table: &str) -> Vec<String> {
    let mut stmt = conn
        .prepare("SELECT name FROM pragma_table_info(?1) ORDER BY cid")
        .unwrap();
    let rows = stmt.query_map([table], |r| r.get::<_, String>(0)).unwrap();
    rows.map(|r| r.unwrap()).collect()
}

/// Every row of `table` in rowid order, as the values of `cols`.
fn table_rows(conn: &Connection, table: &str, cols: &[String]) -> Vec<Vec<SqlValue>> {
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
    rows.map(|r| r.unwrap()).collect()
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

/// The only keys a row may have.
const ROW_FIELDS: &[&str] = &[
    "method",
    "path",
    "request",
    "response",
    "status",
    "headers",
    "dart_only",
];

/// `file` when it is a bare file name in the domain folder: not empty, not
/// `.` or `..`, and with no `/` or `\` (so never absolute and never outside
/// the folder).
fn bare_file_name(name: &str, field: &str, file: String) -> Result<String, String> {
    if file.is_empty() || file == "." || file == ".." || file.contains(['/', '\\']) {
        return Err(format!(
            "{name}: field \"{field}\" must be a bare file name in the domain folder, got {file:?}"
        ));
    }
    Ok(file)
}

fn parse_row(domain: &str, i: usize, v: &Value) -> Result<FixtureRow, String> {
    let name = format!("{domain}[{i}]");
    let obj = v
        .as_object()
        .ok_or_else(|| format!("{name}: a row must be a JSON object"))?;
    if let Some(key) = obj.keys().find(|k| !ROW_FIELDS.contains(&k.as_str())) {
        return Err(format!(
            "{name}: unknown field \"{key}\" (a row has only {})",
            ROW_FIELDS.join(", ")
        ));
    }
    let required_str = |field: &str| -> Result<String, String> {
        match obj.get(field) {
            None | Some(Value::Null) => Err(format!("{name}: missing required field \"{field}\"")),
            Some(Value::String(s)) => Ok(s.clone()),
            Some(_) => Err(format!("{name}: field \"{field}\" must be a string")),
        }
    };
    let method = required_str("method")?;
    let path = required_str("path")?;
    let response = bare_file_name(&name, "response", required_str("response")?)?;
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
        Some(Value::String(s)) => Some(bare_file_name(&name, "request", s.clone())?),
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

/// Every `api_v1/<domain>/` folder that holds an `index.json`, sorted by
/// folder name (one level deep; `api_v1` itself is not a domain). No folder
/// is special-cased: `server/` is a domain once it holds an `index.json`, and
/// files there that no row names (`utc_offsets.json`) are not row files.
pub fn all_domain_dirs() -> Vec<PathBuf> {
    let root = api_v1_dir();
    let entries = fs::read_dir(&root).unwrap_or_else(|e| panic!("read {}: {e}", root.display()));
    let mut dirs: Vec<PathBuf> = entries
        .map(|e| {
            e.unwrap_or_else(|e| panic!("read {}: {e}", root.display()))
                .path()
        })
        .filter(|p| p.is_dir() && p.join(INDEX_FILE).is_file())
        .collect();
    dirs.sort();
    dirs
}

/// Loads `<domain_dir>/index.json` and checks that every `request` and
/// `response` file its rows name exists in the folder. The error lists every
/// missing file as `<domain>[<i>]: <field> file <name> is missing`.
pub fn check_domain_files(domain_dir: &Path) -> Result<(), String> {
    let domain = domain_name(domain_dir);
    let mut missing = Vec::new();
    for (i, row) in load_rows(domain_dir)?.iter().enumerate() {
        let files = [
            ("request", row.request.as_deref()),
            ("response", Some(row.response.as_str())),
        ];
        for (field, file) in files {
            if let Some(file) = file.filter(|f| !domain_dir.join(f).is_file()) {
                missing.push(format!("{domain}[{i}]: {field} file {file} is missing"));
            }
        }
    }
    if missing.is_empty() {
        Ok(())
    } else {
        Err(missing.join("\n"))
    }
}

/// `app/test/fixtures/api_fixtures_parity/index.json`: the row text both the
/// Rust and the Dart row-loader tests parse (AC5). It sits outside `api_v1/`,
/// so it is never a domain and names no real files.
pub fn parity_index_path() -> PathBuf {
    api_v1_dir().join("../api_fixtures_parity/index.json")
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
/// integer literal in `seed_vault.sql`, plus the manifest's values, and the
/// block ids of every table with a `block_id` column.
struct SeedValues {
    text: String,
    ulids: BTreeSet<String>,
    integers: BTreeSet<i64>,
    block_ids: BTreeSet<String>,
}

fn ulid_re() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| Regex::new(r"\b[0-7][0-9A-HJKMNP-TV-Z]{25}\b").unwrap())
}

fn placeholder_re() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| Regex::new(r"^<[a-z_]+(:\d+)?>$").unwrap())
}

/// A whole block id: 6 lowercase Crockford base32 chars (`blocks::short_id`).
fn block_id_re() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| Regex::new(r"^[0-9a-hjkmnp-tv-z]{6}$").unwrap())
}

/// A `[[...]]` link or `![[...]]` transclusion token.
fn link_token_re() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| Regex::new(r"\[\[[^\[\]]*\]\]").unwrap())
}

/// A `^<block id>` ref inside a link token (`#^from`, `..^to`).
fn block_ref_re() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| Regex::new(r"\^([0-9a-hjkmnp-tv-z]{6})\b").unwrap())
}

fn seed_values() -> &'static SeedValues {
    static SEED: OnceLock<SeedValues> = OnceLock::new();
    SEED.get_or_init(|| {
        let sql = seed_sql();
        let block_ids = block_ids_of(&seed_connection(&sql));
        let mut text = sql;
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
            block_ids,
        }
    })
}

/// Every value of every `block_id` column in `conn`.
fn block_ids_of(conn: &Connection) -> BTreeSet<String> {
    let tables: Vec<String> = {
        let mut stmt = conn
            .prepare(
                "SELECT m.name FROM sqlite_master m, pragma_table_info(m.name) c
                 WHERE m.type = 'table' AND c.name = 'block_id' ORDER BY m.name",
            )
            .unwrap();
        let rows = stmt.query_map([], |r| r.get::<_, String>(0)).unwrap();
        rows.map(|r| r.unwrap()).collect()
    };
    let mut ids = BTreeSet::new();
    for table in tables {
        let mut stmt = conn
            .prepare(&format!("SELECT block_id FROM \"{table}\""))
            .unwrap();
        let rows = stmt.query_map([], |r| r.get::<_, String>(0)).unwrap();
        ids.extend(rows.map(|r| r.unwrap()));
    }
    ids
}

const ID_PLACEHOLDER: &str = "id";
const BLOCK_PLACEHOLDER: &str = "block";
const TIMESTAMP_PLACEHOLDER: &str = "<timestamp>";

/// The placeholders handed out so far, per kind, keyed by the minted value.
#[derive(Default)]
struct Minted {
    ids: HashMap<String, String>,
    blocks: HashMap<String, String>,
}

impl Minted {
    fn id(&mut self, token: &str) -> String {
        let next = self.ids.len() + 1;
        self.ids
            .entry(token.to_string())
            .or_insert_with(|| format!("<{ID_PLACEHOLDER}:{next}>"))
            .clone()
    }

    fn block(&mut self, token: &str) -> String {
        let next = self.blocks.len() + 1;
        self.blocks
            .entry(token.to_string())
            .or_insert_with(|| format!("<{BLOCK_PLACEHOLDER}:{next}>"))
            .clone()
    }
}

/// Replaces the values a write mints with stable placeholders, against the
/// committed seed:
///
/// - a ULID (a whole string, or a ULID-shaped token inside a longer string)
///   that the seed does not hold becomes `<id:N>`, numbered by first
///   appearance (object keys visited in sorted order), so the same minted id
///   gets the same placeholder everywhere in the value;
/// - a block id (6 lowercase Crockford base32 chars) that no seed table
///   holds becomes `<block:N>`, numbered the same way but separately from
///   `<id:N>`: a whole string under a `block_id` or `block_ids` key (arrays
///   included), and every `^<block id>` ref inside a `[[...]]` or `![[...]]`
///   token in any string (`![[2026-10-19#^<block:1>..^<block:2>]]`);
/// - a number or string under a key ending in `_at` that the seed does not
///   hold becomes `"<timestamp>"`.
///
/// Seed ids, seed block ids, seed timestamps, object keys and every other
/// value are left as they are, and placeholders are themselves left alone,
/// so the function is idempotent and its output is the same across runs.
pub fn normalize_volatile(v: &Value) -> Value {
    normalize_value(v, None, seed_values(), &mut Minted::default())
}

fn normalize_value(v: &Value, key: Option<&str>, seed: &SeedValues, minted: &mut Minted) -> Value {
    let is_time_key = key.is_some_and(|k| k.ends_with("_at"));
    let is_block_key = key.is_some_and(|k| k == "block_id" || k == "block_ids");
    match v {
        Value::Object(m) => {
            let mut keys: Vec<&String> = m.keys().collect();
            keys.sort();
            let mut out = Map::new();
            for k in keys {
                out.insert(k.clone(), normalize_value(&m[k], Some(k), seed, minted));
            }
            Value::Object(out)
        }
        Value::Array(a) => Value::Array(
            a.iter()
                .map(|x| normalize_value(x, key, seed, minted))
                .collect(),
        ),
        Value::Number(n) if is_time_key => match n.as_i64() {
            Some(i) if seed.integers.contains(&i) => v.clone(),
            _ => Value::String(TIMESTAMP_PLACEHOLDER.to_string()),
        },
        Value::String(s) if placeholder_re().is_match(s) => v.clone(),
        Value::String(s) if is_block_key && block_id_re().is_match(s) => {
            if seed.block_ids.contains(s) {
                v.clone()
            } else {
                Value::String(minted.block(s))
            }
        }
        Value::String(s) => {
            let replaced = ulid_re().replace_all(s, |c: &regex::Captures| {
                let token = &c[0];
                if seed.ulids.contains(token) {
                    token.to_string()
                } else {
                    minted.id(token)
                }
            });
            let replaced = link_token_re().replace_all(&replaced, |link: &regex::Captures| {
                block_ref_re()
                    .replace_all(&link[0], |r: &regex::Captures| {
                        let id = &r[1];
                        if seed.block_ids.contains(id) {
                            r[0].to_string()
                        } else {
                            format!("^{}", minted.block(id))
                        }
                    })
                    .into_owned()
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

/// `vault_schema_v5.sql` (schema and its data rows, no search-index tables).
pub fn schema_v5_sql() -> String {
    read_string(&api_v1_dir().join("../vault_schema_v5.sql"))
}

/// An in-memory database holding `vault_schema_v5.sql` plus `seed_sql`,
/// loaded in one transaction with deferred foreign keys.
pub fn seed_connection(seed_sql: &str) -> Connection {
    let mut conn = Connection::open_in_memory().expect("in-memory database");
    conn.execute_batch(&schema_v5_sql())
        .expect("load vault_schema_v5.sql");
    let tx = conn.transaction().expect("begin seed load");
    tx.pragma_update(None, "defer_foreign_keys", "ON")
        .expect("defer foreign keys");
    tx.execute_batch(seed_sql)
        .unwrap_or_else(|e| panic!("load seed SQL on vault_schema_v5.sql: {e}"));
    tx.commit().expect("commit seed load");
    conn
}

/// A structural summary of a seed, for the seed-drift check: build a seed
/// into scratch with [`run_seed_builder`] and compare
/// `seed_summary(&built)` with `seed_summary(&seed_sql())`.
///
/// `{"<table>": {"count": N, "rows": [{"<column>": value, ...}, ...]}}` for
/// every table the seed SQL fills (same tables as the dump), with the values
/// a rebuild re-mints replaced by stable labels:
///
/// - a note id becomes `<note:TITLE>`, a Smart Folder id `<folder:NAME>`, a
///   canvas id `<canvas:TITLE>`, and a block id `<block:TITLE#ORD>` (the
///   note title and `ord` of its `blocks` row; `<block>` when no `blocks` row
///   holds it), both as whole values and as ULID tokens or `^<block id>`
///   refs inside link tokens of longer text;
/// - any other ULID becomes `<ulid>`;
/// - every value of a column ending in `_at` becomes `<timestamp>`;
/// - a blob becomes its upper-case hex.
///
/// Rows are sorted by their canonical JSON, so row order does not matter.
pub fn seed_summary(seed_sql: &str) -> Value {
    let conn = seed_connection(seed_sql);
    let labels = seed_labels(&conn);
    let mut out = Map::new();
    for table in seed_tables(&conn) {
        let cols = table_columns(&conn, &table);
        let mut rows: Vec<Value> = table_rows(&conn, &table, &cols)
            .into_iter()
            .map(|values| {
                let mut row = Map::new();
                for (col, value) in cols.iter().zip(values) {
                    row.insert(col.clone(), summary_value(col, &value, &labels));
                }
                Value::Object(row)
            })
            .collect();
        rows.sort_by_cached_key(canonical_json);
        let mut entry = Map::new();
        entry.insert("count".to_string(), Value::from(rows.len()));
        entry.insert("rows".to_string(), Value::Array(rows));
        out.insert(table, Value::Object(entry));
    }
    Value::Object(out)
}

/// Seed ids and block ids mapped to their stable labels.
struct SeedLabels {
    ids: HashMap<String, String>,
    blocks: HashMap<String, String>,
}

fn seed_labels(conn: &Connection) -> SeedLabels {
    let pairs = |sql: &str| -> Vec<(String, String)> {
        let mut stmt = conn.prepare(sql).unwrap();
        let rows = stmt
            .query_map([], |r| Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?)))
            .unwrap();
        rows.map(|r| r.unwrap()).collect()
    };
    let mut ids = HashMap::new();
    for (sql, kind) in [
        ("SELECT id, title FROM notes", "note"),
        ("SELECT id, name FROM smart_folders", "folder"),
        ("SELECT id, title FROM canvases", "canvas"),
    ] {
        for (id, name) in pairs(sql) {
            ids.insert(id, format!("<{kind}:{name}>"));
        }
    }
    let blocks = pairs(
        "SELECT b.block_id, n.title || '#' || b.ord FROM blocks b JOIN notes n ON n.id = b.note_id",
    )
    .into_iter()
    .map(|(id, at)| (id, format!("<block:{at}>")))
    .collect();
    SeedLabels { ids, blocks }
}

fn summary_value(col: &str, v: &SqlValue, labels: &SeedLabels) -> Value {
    if col.ends_with("_at") && *v != SqlValue::Null {
        return Value::String(TIMESTAMP_PLACEHOLDER.to_string());
    }
    match v {
        SqlValue::Null => Value::Null,
        SqlValue::Integer(i) => Value::from(*i),
        SqlValue::Real(f) => Value::from(*f),
        SqlValue::Blob(b) => Value::String(b.iter().map(|x| format!("{x:02X}")).collect()),
        SqlValue::Text(s) if col == "block_id" => Value::String(
            labels
                .blocks
                .get(s)
                .cloned()
                .unwrap_or_else(|| format!("<{BLOCK_PLACEHOLDER}>")),
        ),
        SqlValue::Text(s) => {
            let text = ulid_re().replace_all(s, |c: &regex::Captures| {
                labels
                    .ids
                    .get(&c[0])
                    .cloned()
                    .unwrap_or_else(|| "<ulid>".to_string())
            });
            let text = link_token_re().replace_all(&text, |link: &regex::Captures| {
                block_ref_re()
                    .replace_all(&link[0], |r: &regex::Captures| {
                        let label = labels
                            .blocks
                            .get(&r[1])
                            .cloned()
                            .unwrap_or_else(|| format!("<{BLOCK_PLACEHOLDER}>"));
                        format!("^{label}")
                    })
                    .into_owned()
            });
            Value::String(text.into_owned())
        }
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
