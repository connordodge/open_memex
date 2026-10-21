//! WI #85 (V5): the graph and activity reads of the app API
//! (`app_reads::graph`) hold the rules of the app's local `GraphReads`
//! (app/lib/src/db/graph_reads.dart) and `ActivityReads`
//! (app/lib/src/db/activity_reads.dart):
//!
//! - notes come ordered by id; `role` is
//!   `CASE WHEN json_valid(frontmatter) THEN json_extract(frontmatter,'$.role') END`
//!   kept only when SQLite hands it back as text, so invalid JSON, a missing
//!   role and a number, boolean or null role are all `None`, a string role is
//!   kept as stored, and an object or array role is its JSON text (that is
//!   what `json_extract` returns for one, and the Dart side keeps any text);
//! - links are inner-joined to an existing target note (ghost links, with a
//!   NULL target, and links to a note id that no longer exists are left out),
//!   ordered by `from_note_id`, then `position`;
//! - agent changes are the note's rows by `created_at` DESC, then `rowid`
//!   DESC; `bullets_json` that is not text, not valid JSON or not a list
//!   decodes to `[]`, and list items that are not strings become their Dart
//!   string form (`'$b'`: `1`, `true`, `null`); an unknown note has none.
//!
//! The vault server's fixture rows (`crates/memex-mcp/tests/api_graph.rs`)
//! check the same reads on #74's seed; these cases add the edge rows the seed
//! has no room for, written straight into a fresh vault's tables.
//!
//! API under test (memex_core::app_reads::graph):
//!   graph_notes(&Vault) -> Result<Vec<GraphNoteRow>>
//!   graph_links(&Vault) -> Result<Vec<GraphLinkRow>>
//!   agent_changes(&Vault, &str) -> Result<Vec<AgentChangeRow>>

use memex_core::app_reads::graph::{
    agent_changes, graph_links, graph_notes, AgentChangeRow, GraphLinkRow, GraphNoteRow,
};
use memex_core::Vault;
use rusqlite::params;
use rusqlite::types::Value as SqlValue;
use tempfile::TempDir;

fn fresh_vault() -> (TempDir, Vault) {
    let dir = tempfile::tempdir().unwrap();
    let vault = Vault::create(dir.path()).unwrap();
    (dir, vault)
}

fn note(vault: &Vault, id: &str, title: &str, frontmatter: &str) {
    vault
        .connection_ref()
        .execute(
            "INSERT INTO notes (id, title, content_md, frontmatter, version, created_at, updated_at)
             VALUES (?, ?, '', ?, 1, 1760000000000, 1760000000000)",
            params![id, title, frontmatter],
        )
        .unwrap();
}

fn link(
    vault: &Vault,
    id: &str,
    from: &str,
    to: Option<&str>,
    kind: &str,
    label: Option<&str>,
    position: i64,
) {
    vault
        .connection_ref()
        .execute(
            "INSERT INTO links (id, from_note_id, to_note_id, link_text, link_kind, label,
                                position, source)
             VALUES (?, ?, ?, 'text', ?, ?, ?, 'inline_body')",
            params![id, from, to, kind, label, position],
        )
        .unwrap();
}

/// One `agent_changes` row; `bullets` goes in as the given SQL value.
fn change(vault: &Vault, id: &str, note_id: &str, day: &str, created_at: i64, bullets: SqlValue) {
    vault
        .connection_ref()
        .execute(
            "INSERT INTO agent_changes (id, note_id, day, created_at, bullets_json)
             VALUES (?, ?, ?, ?, ?)",
            params![id, note_id, day, created_at, bullets],
        )
        .unwrap();
}

fn text(s: &str) -> SqlValue {
    SqlValue::Text(s.to_string())
}

fn note_row(id: &str, title: &str, role: Option<&str>) -> GraphNoteRow {
    GraphNoteRow {
        id: id.to_string(),
        title: title.to_string(),
        role: role.map(str::to_string),
    }
}

fn link_row(from: &str, to: &str, kind: &str, label: Option<&str>) -> GraphLinkRow {
    GraphLinkRow {
        from: from.to_string(),
        to: to.to_string(),
        kind: kind.to_string(),
        label: label.map(str::to_string),
    }
}

fn change_row(
    id: &str,
    note_id: &str,
    day: &str,
    created_at: i64,
    bullets: &[&str],
) -> AgentChangeRow {
    AgentChangeRow {
        id: id.to_string(),
        note_id: note_id.to_string(),
        day: day.to_string(),
        created_at,
        bullets: bullets.iter().map(|b| b.to_string()).collect(),
    }
}

/// `(id, role)` of every graph note.
fn roles(vault: &Vault) -> Vec<(String, Option<String>)> {
    graph_notes(vault)
        .unwrap()
        .into_iter()
        .map(|n| (n.id, n.role))
        .collect()
}

// ---------------------------------------------------------------------------
// graph_notes: role
// ---------------------------------------------------------------------------

#[test]
fn graph_notes_role_is_null_for_invalid_json_a_non_string_role_and_no_role() {
    let (_dir, vault) = fresh_vault();
    let cases: &[(&str, &str)] = &[
        // Invalid JSON (the seed's Broken Frontmatter shape, and others).
        ("N01", r#"{"role": "topic""#),
        ("N02", "not json"),
        ("N03", ""),
        ("N04", r#"{"role":"daily",}"#),
        // A role that is not a string.
        ("N05", r#"{"role":5}"#),
        ("N06", r#"{"role":1.5}"#),
        ("N07", r#"{"role":true}"#),
        ("N08", r#"{"role":false}"#),
        ("N09", r#"{"role":null}"#),
        // No role.
        ("N10", "{}"),
        ("N11", r#"{"tags":["daily"],"kind":"topic"}"#),
        ("N12", r#"{"Role":"daily"}"#),
        // Valid JSON that is not an object.
        ("N13", r#"["daily"]"#),
        ("N14", r#""daily""#),
        ("N15", "42"),
        ("N16", "null"),
    ];
    for (i, (id, fm)) in cases.iter().enumerate() {
        note(&vault, id, &format!("Note {i}"), fm);
    }
    let want: Vec<(String, Option<String>)> =
        cases.iter().map(|(id, _)| (id.to_string(), None)).collect();
    assert_eq!(roles(&vault), want);
}

#[test]
fn graph_notes_keep_daily_topic_and_any_other_string_role_as_stored() {
    let (_dir, vault) = fresh_vault();
    note(&vault, "A1", "2026-10-01", r#"{"role":"daily"}"#);
    note(&vault, "A2", "Topic", r#"{"role":"topic","tags":["x"]}"#);
    note(&vault, "A3", "Capital", r#"{"role":"Daily"}"#);
    note(&vault, "A4", "Person", r#"{ "role" : "person" }"#);
    note(&vault, "A5", "Empty", r#"{"role":""}"#);
    note(&vault, "A6", "Glyph", r#"{"role":"töpic 🎲"}"#);
    assert_eq!(
        graph_notes(&vault).unwrap(),
        vec![
            note_row("A1", "2026-10-01", Some("daily")),
            note_row("A2", "Topic", Some("topic")),
            note_row("A3", "Capital", Some("Daily")),
            note_row("A4", "Person", Some("person")),
            note_row("A5", "Empty", Some("")),
            note_row("A6", "Glyph", Some("töpic 🎲")),
        ]
    );
}

#[test]
fn graph_notes_role_that_is_an_object_or_array_is_its_json_text_like_the_local_sql() {
    let (_dir, vault) = fresh_vault();
    note(&vault, "B1", "Array", r#"{"role": ["daily", "topic"]}"#);
    note(&vault, "B2", "Object", r#"{"role": {"a": 1}}"#);
    assert_eq!(
        roles(&vault),
        vec![
            ("B1".to_string(), Some(r#"["daily","topic"]"#.to_string())),
            ("B2".to_string(), Some(r#"{"a":1}"#.to_string())),
        ]
    );
}

#[test]
fn graph_notes_are_every_note_ordered_by_id() {
    let (_dir, vault) = fresh_vault();
    // Inserted out of order; ids compare as bytes (uppercase before
    // lowercase), never by title or insertion order.
    note(&vault, "C", "Alpha", r#"{"role":"topic"}"#);
    note(&vault, "a", "Bravo", "{}");
    note(&vault, "B", "Charlie", r#"{"role":"daily"}"#);
    note(&vault, "AB", "Delta", "{}");
    assert_eq!(
        graph_notes(&vault).unwrap(),
        vec![
            note_row("AB", "Delta", None),
            note_row("B", "Charlie", Some("daily")),
            note_row("C", "Alpha", Some("topic")),
            note_row("a", "Bravo", None),
        ]
    );
}

#[test]
fn graph_notes_on_an_empty_vault_is_empty() {
    let (_dir, vault) = fresh_vault();
    assert_eq!(graph_notes(&vault).unwrap(), vec![]);
    assert_eq!(graph_links(&vault).unwrap(), vec![]);
}

// ---------------------------------------------------------------------------
// graph_links
// ---------------------------------------------------------------------------

#[test]
fn graph_links_keep_only_links_to_an_existing_note_ordered_by_source_then_position() {
    let (_dir, vault) = fresh_vault();
    note(&vault, "N1", "One", "{}");
    note(&vault, "N2", "Two", "{}");
    note(&vault, "N3", "Three", "{}");
    // Inserted out of order on purpose.
    link(&vault, "L5", "N2", Some("N1"), "extends", None, 40);
    link(&vault, "L1", "N1", Some("N3"), "about", Some("why"), 90);
    link(&vault, "L2", "N1", None, "references", None, 10); // ghost link
    link(&vault, "L3", "N1", Some("N2"), "references", None, 30);
    link(&vault, "L4", "N3", Some("N3"), "references", Some(""), 5); // self link
    link(&vault, "L6", "N2", Some("N3"), "from-day", None, 2);
    // A link whose target id no longer names a note (written with foreign
    // keys off, as an old vault might hold it).
    let conn = vault.connection_ref();
    conn.pragma_update(None, "foreign_keys", "OFF").unwrap();
    link(&vault, "L7", "N1", Some("GONE"), "references", None, 20);
    conn.pragma_update(None, "foreign_keys", "ON").unwrap();

    assert_eq!(
        graph_links(&vault).unwrap(),
        vec![
            link_row("N1", "N2", "references", None),
            link_row("N1", "N3", "about", Some("why")),
            link_row("N2", "N3", "from-day", None),
            link_row("N2", "N1", "extends", None),
            link_row("N3", "N3", "references", Some("")),
        ]
    );
}

// ---------------------------------------------------------------------------
// agent_changes
// ---------------------------------------------------------------------------

#[test]
fn agent_changes_with_equal_created_at_come_newest_inserted_first() {
    let (_dir, vault) = fresh_vault();
    note(&vault, "N1", "One", "{}");
    // Equal created_at: insertion order decides, newest first. The ids sort
    // neither way, so an id tie-break would give another order.
    change(&vault, "Z", "N1", "2026-10-18", 1000, text(r#"["z"]"#));
    change(&vault, "A", "N1", "2026-10-18", 1000, text(r#"["a"]"#));
    change(&vault, "M", "N1", "2026-10-18", 1000, text(r#"["m"]"#));
    // A newer created_at comes first even when inserted first; an older one
    // last even when inserted last.
    change(&vault, "OLD", "N1", "2026-10-17", 999, text(r#"["old"]"#));
    let ids: Vec<String> = agent_changes(&vault, "N1")
        .unwrap()
        .into_iter()
        .map(|c| c.id)
        .collect();
    assert_eq!(ids, vec!["M", "A", "Z", "OLD"]);

    let (_dir2, vault2) = fresh_vault();
    note(&vault2, "N1", "One", "{}");
    change(&vault2, "NEW", "N1", "2026-10-19", 2000, text("[]"));
    change(&vault2, "B", "N1", "2026-10-18", 1000, text("[]"));
    change(&vault2, "C", "N1", "2026-10-18", 1000, text("[]"));
    let ids: Vec<String> = agent_changes(&vault2, "N1")
        .unwrap()
        .into_iter()
        .map(|c| c.id)
        .collect();
    assert_eq!(ids, vec!["NEW", "C", "B"]);
}

#[test]
fn agent_changes_decode_bullets_that_are_not_valid_json_or_not_a_list_to_empty() {
    let (_dir, vault) = fresh_vault();
    note(&vault, "N1", "One", "{}");
    let cases: &[(&str, &str)] = &[
        // Not valid JSON.
        ("C01", "not json"),
        ("C02", r#"["unterminated""#),
        ("C03", ""),
        ("C04", r#"["a",]"#),
        // Valid JSON that is not a list.
        ("C05", r#"{"bullets":["a"]}"#),
        ("C06", r#""a bullet""#),
        ("C07", "42"),
        ("C08", "true"),
        ("C09", "null"),
    ];
    // Distinct created_at, newest first in the order listed.
    for (i, (id, raw)) in cases.iter().enumerate() {
        change(&vault, id, "N1", "2026-10-18", 1000 - i as i64, text(raw));
    }
    assert_eq!(
        agent_changes(&vault, "N1").unwrap(),
        cases
            .iter()
            .enumerate()
            .map(|(i, (id, _))| change_row(id, "N1", "2026-10-18", 1000 - i as i64, &[]))
            .collect::<Vec<_>>()
    );
}

#[test]
fn agent_changes_bullets_stored_as_a_blob_decode_to_empty() {
    // `bullets_json` that is not text (`raw is! String` in the Dart read).
    let (_dir, vault) = fresh_vault();
    note(&vault, "N1", "One", "{}");
    change(
        &vault,
        "BLOB",
        "N1",
        "2026-10-18",
        5,
        SqlValue::Blob(br#"["a"]"#.to_vec()),
    );
    assert_eq!(
        agent_changes(&vault, "N1").unwrap(),
        vec![change_row("BLOB", "N1", "2026-10-18", 5, &[])]
    );
}

#[test]
fn agent_changes_keep_a_list_of_bullets_in_stored_order() {
    let (_dir, vault) = fresh_vault();
    note(&vault, "N1", "One", "{}");
    change(
        &vault,
        "LIST",
        "N1",
        "2026-10-19",
        1792535788530,
        text(r#"["Second idea","First idea","Größe 🎲 \"quoted\""]"#),
    );
    change(
        &vault,
        "EMPTY",
        "N1",
        "2026-10-18",
        1760000960000,
        text("[]"),
    );
    assert_eq!(
        agent_changes(&vault, "N1").unwrap(),
        vec![
            change_row(
                "LIST",
                "N1",
                "2026-10-19",
                1792535788530,
                &["Second idea", "First idea", "Größe 🎲 \"quoted\""],
            ),
            change_row("EMPTY", "N1", "2026-10-18", 1760000960000, &[]),
        ]
    );
}

#[test]
fn agent_changes_turn_number_bool_and_null_bullets_into_their_dart_strings() {
    let (_dir, vault) = fresh_vault();
    note(&vault, "N1", "One", "{}");
    change(
        &vault,
        "MIX",
        "N1",
        "2026-10-18",
        7,
        text(r#"[1, true, false, null, "x", -3]"#),
    );
    assert_eq!(
        agent_changes(&vault, "N1").unwrap(),
        vec![change_row(
            "MIX",
            "N1",
            "2026-10-18",
            7,
            &["1", "true", "false", "null", "x", "-3"],
        )]
    );
}

#[test]
fn agent_changes_are_only_the_given_notes_rows_and_none_for_an_unknown_note() {
    let (_dir, vault) = fresh_vault();
    note(&vault, "N1", "One", "{}");
    note(&vault, "N2", "Two", "{}");
    note(&vault, "N3", "Three", "{}");
    change(&vault, "X1", "N1", "2026-10-18", 10, text(r#"["one"]"#));
    change(&vault, "X2", "N2", "2026-10-18", 20, text(r#"["two"]"#));
    change(&vault, "X3", "N1", "2026-10-19", 30, text(r#"["three"]"#));
    assert_eq!(
        agent_changes(&vault, "N1").unwrap(),
        vec![
            change_row("X3", "N1", "2026-10-19", 30, &["three"]),
            change_row("X1", "N1", "2026-10-18", 10, &["one"]),
        ]
    );
    assert_eq!(
        agent_changes(&vault, "N2").unwrap(),
        vec![change_row("X2", "N2", "2026-10-18", 20, &["two"])]
    );
    for unknown in ["N3", "NOPE", "", "01J9Z8Y7X6W5V4T3S2R1Q0P9N8", "n1", "N1 "] {
        assert_eq!(
            agent_changes(&vault, unknown).unwrap(),
            vec![],
            "{unknown:?}"
        );
    }
}

// ---------- bullets the one writer can store ----------
//
// `dart_string` and Dart's `'$b'` part ways on bullet items no writer
// stores: `-0` (Rust "-0.0", Dart "0"), numbers past i64 or JSON overflow
// (`1e400`: Rust `[]`, Dart "Infinity"), large doubles below 1e21 (Rust prints
// the exact value, Dart the shortest digits padded with zeros) and objects
// (serde_json sorts keys, Dart keeps insertion order). The only writer of
// `agent_changes` is `review::mark_day_reviewed` (core; the MCP
// `mark_day_reviewed` tool and the CLI call it), which stores
// `serde_json::to_string(&Vec<String>)`: a JSON list of strings, which both
// sides return verbatim. These two tests pin that, so a new writer that could
// store a non-string item has to face the parity gap.

/// Every `.rs` / `.dart` file under `dir`, recursively.
fn source_files(dir: &std::path::Path, out: &mut Vec<std::path::PathBuf>) {
    for entry in std::fs::read_dir(dir).unwrap() {
        let path = entry.unwrap().path();
        if path.is_dir() {
            source_files(&path, out);
        } else if matches!(
            path.extension().and_then(|e| e.to_str()),
            Some("rs" | "dart")
        ) {
            out.push(path);
        }
    }
}

#[test]
fn agent_changes_have_one_writer_the_day_review_in_core() {
    let root = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../..");
    let mut files = Vec::new();
    source_files(&root.join("crates"), &mut files);
    source_files(&root.join("app/lib"), &mut files);
    let mut writers: Vec<String> = files
        .iter()
        .filter(|f| !f.components().any(|c| c.as_os_str() == "tests"))
        .filter(|f| writes_agent_changes(&std::fs::read_to_string(f).unwrap()))
        .map(|f| {
            f.strip_prefix(&root)
                .unwrap()
                .to_string_lossy()
                .replace('\\', "/")
        })
        .collect();
    writers.sort();
    assert_eq!(writers, vec!["crates/memex-core/src/review.rs".to_string()]);
}

/// Whether `source` writes the `agent_changes` table (an INSERT, REPLACE or
/// UPDATE naming it), whatever the case and spacing.
fn writes_agent_changes(source: &str) -> bool {
    let flat: String = source
        .to_ascii_lowercase()
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ");
    [
        "insert into agent_changes",
        "insert or replace into agent_changes",
        "insert or ignore into agent_changes",
        "replace into agent_changes",
        "update agent_changes",
    ]
    .iter()
    .any(|w| flat.contains(w))
}

#[test]
fn agent_changes_from_the_day_review_store_strings_that_read_back_verbatim() {
    use memex_core::canvas::Clock;
    use memex_core::notes::{create_note_as, CreateNote};
    use memex_core::review::{mark_day_reviewed, ChangeEntry};
    use memex_core::Caller;

    struct At(i64);
    impl Clock for At {
        fn now_ms(&self) -> i64 {
            self.0
        }
    }

    let (_dir, mut vault) = fresh_vault();
    let mut create = |title: &str, body: &str, frontmatter: serde_json::Value| {
        create_note_as(
            &mut vault,
            CreateNote {
                title: Some(title.into()),
                content_md: body.into(),
                frontmatter: Some(frontmatter),
            },
            Caller::Person,
        )
        .unwrap()
        .id
        .to_string()
    };
    let topic = create(
        "Economy",
        "A topic.",
        serde_json::json!({ "role": "topic" }),
    );
    let day = create(
        "2026-10-18",
        "Tuned prices.\n",
        serde_json::json!({ "role": "daily" }),
    );
    // Bullets that would be the divergent items if stored as JSON values.
    let day_bullets = ["1.0", "-0", "1e400"];
    let topic_bullets = [
        r#"{"b":1,"a":"x"}"#,
        "9223372036854775808",
        r#"[2, {"z":0,"y":1}]"#,
    ];
    let entry = |note_id: &str, bullets: &[&str]| ChangeEntry {
        note_id: note_id.to_string(),
        bullets: bullets.iter().map(|b| b.to_string()).collect(),
    };
    mark_day_reviewed(
        &mut vault,
        "2026-10-18",
        1,
        &[entry(&day, &day_bullets), entry(&topic, &topic_bullets)],
        &At(1760000960000),
    )
    .unwrap();

    for (note_id, bullets) in [(&day, &day_bullets), (&topic, &topic_bullets)] {
        let raw: String = vault
            .connection_ref()
            .query_row(
                "SELECT bullets_json FROM agent_changes WHERE note_id = ?",
                [note_id],
                |r| r.get(0),
            )
            .unwrap();
        let stored: serde_json::Value = serde_json::from_str(&raw).unwrap();
        let items = stored.as_array().expect("bullets_json is a JSON list");
        assert!(items.iter().all(|i| i.is_string()), "{raw}");
        let rows = agent_changes(&vault, note_id).unwrap();
        assert_eq!(rows.len(), 1, "{rows:?}");
        assert_eq!(rows[0].bullets, bullets.to_vec(), "{raw}");
    }
}
