use std::fs;

use memex_core::notes::{create_note, get_note, list_notes, update_note, CreateNote, UpdateNote};
use memex_core::{MemexError, Vault};
use rusqlite::params;

#[test]
fn vault_create_writes_manifest_db_objects_and_schema() {
    let dir = tempfile::tempdir().unwrap();
    let root = dir.path().to_path_buf();

    let vault = Vault::create(&root).expect("create vault");

    assert!(root.join("manifest.json").exists(), "manifest.json must exist");
    assert!(root.join("memex.db").exists(), "memex.db must exist");
    assert!(
        root.join("objects").is_dir(),
        "objects/ must exist as a directory"
    );

    // manifest is well-formed JSON with vault_id + current schema_version
    let manifest_text = fs::read_to_string(root.join("manifest.json")).unwrap();
    let manifest: serde_json::Value = serde_json::from_str(&manifest_text).unwrap();
    let app_v = memex_core::schema::APP_SCHEMA_VERSION;
    assert_eq!(
        manifest["schema_version"].as_i64().unwrap(),
        app_v
    );
    assert!(manifest["vault_id"].as_str().unwrap().len() == 26, "vault_id is a ULID");

    // schema_version table populated
    assert_eq!(vault.schema_version(), app_v);

    // notes table exists and is empty
    let count: i64 = vault
        .connection_ref()
        .query_row("SELECT COUNT(*) FROM notes", [], |r| r.get(0))
        .unwrap();
    assert_eq!(count, 0);
}

#[test]
fn vault_round_trip_persists_notes_across_open() {
    let dir = tempfile::tempdir().unwrap();
    let root = dir.path().to_path_buf();
    let mut vault = Vault::create(&root).unwrap();

    let n1 = create_note(
        &mut vault,
        CreateNote {
            title: Some("Hello".into()),
            content_md: "# Hello\n\nThis is the first note.".into(),
            ..Default::default()
        },
    )
    .unwrap();
    let n2 = create_note(
        &mut vault,
        CreateNote {
            title: None,
            content_md: "# Second\n\nAnother note here.".into(),
            ..Default::default()
        },
    )
    .unwrap();

    drop(vault);

    let vault = Vault::open(&root).expect("re-open");
    let listed = list_notes(&vault, 100).unwrap();
    assert_eq!(listed.len(), 2);

    let got1 = get_note(&vault, &n1.id).unwrap();
    assert_eq!(got1.title, "Hello");
    assert!(got1.content_md.contains("first note"));
    assert_eq!(got1.version, 1);

    let got2 = get_note(&vault, &n2.id).unwrap();
    assert_eq!(got2.title, "Second");
}

#[test]
fn update_note_with_stale_expected_version_returns_version_conflict() {
    let dir = tempfile::tempdir().unwrap();
    let mut vault = Vault::create(dir.path()).unwrap();

    let note = create_note(
        &mut vault,
        CreateNote {
            content_md: "v1".into(),
            ..Default::default()
        },
    )
    .unwrap();
    assert_eq!(note.version, 1);

    // First update: matches expected_version=1, becomes v2.
    let updated = update_note(
        &mut vault,
        &note.id,
        1,
        UpdateNote {
            content_md: Some("v2".into()),
            ..Default::default()
        },
    )
    .unwrap();
    assert_eq!(updated.version, 2);

    // Second update at stale expected_version=1 must conflict and report current=2.
    let err = update_note(
        &mut vault,
        &note.id,
        1,
        UpdateNote {
            content_md: Some("v3-attempt".into()),
            ..Default::default()
        },
    )
    .unwrap_err();
    match err {
        MemexError::VersionConflict { expected, current } => {
            assert_eq!(expected, 1);
            assert_eq!(current, 2);
        }
        other => panic!("expected VersionConflict, got {other:?}"),
    }

    // Note is unchanged at v2.
    let after = get_note(&vault, &note.id).unwrap();
    assert_eq!(after.version, 2);
    assert_eq!(after.content_md, "v2");
}

#[test]
fn sqlite_vec_extension_is_loaded_and_usable() {
    // Smoke test: prove sqlite-vec auto-extension registration works
    // and we can create + query a vec0 virtual table on this connection.
    let dir = tempfile::tempdir().unwrap();
    let vault = Vault::create(dir.path()).unwrap();
    let conn = vault.connection_ref();

    conn.execute_batch(
        r#"
        CREATE VIRTUAL TABLE vec_smoke USING vec0(
            id INTEGER PRIMARY KEY,
            embedding float[3]
        );
        "#,
    )
    .expect("create vec0 table");

    // Insert two vectors.
    let a: [f32; 3] = [1.0, 0.0, 0.0];
    let b: [f32; 3] = [0.0, 1.0, 0.0];
    let q: [f32; 3] = [0.9, 0.1, 0.0];
    conn.execute(
        "INSERT INTO vec_smoke(id, embedding) VALUES (?, ?)",
        params![1i64, bytes_of_floats(&a)],
    )
    .unwrap();
    conn.execute(
        "INSERT INTO vec_smoke(id, embedding) VALUES (?, ?)",
        params![2i64, bytes_of_floats(&b)],
    )
    .unwrap();

    let mut stmt = conn
        .prepare("SELECT id FROM vec_smoke WHERE embedding MATCH ? AND k = 1 ORDER BY distance")
        .unwrap();
    let mut rows = stmt.query(params![bytes_of_floats(&q)]).unwrap();
    let row = rows.next().unwrap().expect("at least one row");
    let id: i64 = row.get(0).unwrap();
    assert_eq!(id, 1, "nearest vector should be id=1");
}

fn bytes_of_floats(v: &[f32]) -> Vec<u8> {
    let mut out = Vec::with_capacity(v.len() * 4);
    for f in v {
        out.extend_from_slice(&f.to_le_bytes());
    }
    out
}
