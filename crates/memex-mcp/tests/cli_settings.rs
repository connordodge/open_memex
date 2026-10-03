//! WI #14 (R11): `memex settings get|set` (CONTRACTS C2.11, error contract
//! C1). Drives the real `memex` binary against temp vaults.

use std::collections::BTreeSet;
use std::process::{Command, Output, Stdio};

use memex_core::schema;
use rusqlite::Connection;
use serde_json::{json, Value};
use tempfile::TempDir;

const KEY: &str = "smart_folder_max_depth";

fn run(args: &[&str]) -> Output {
    Command::new(env!("CARGO_BIN_EXE_memex"))
        .args(args)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .output()
        .expect("run memex")
}

fn describe(out: &Output) -> String {
    format!(
        "exit={:?}\nstdout={}\nstderr={}",
        out.status.code(),
        String::from_utf8_lossy(&out.stdout),
        String::from_utf8_lossy(&out.stderr)
    )
}

/// Success: exit 0, stdout is exactly one JSON line; returns it parsed.
fn ok_json(out: Output) -> Value {
    assert!(
        out.status.success(),
        "expected success, got {}",
        describe(&out)
    );
    let stdout = String::from_utf8(out.stdout).expect("utf8 stdout");
    let line = stdout.strip_suffix('\n').unwrap_or(&stdout);
    assert!(
        !line.is_empty() && !line.contains('\n'),
        "stdout must be exactly one JSON line, got {stdout:?}"
    );
    serde_json::from_str(line).unwrap_or_else(|e| panic!("stdout is not JSON ({e}): {stdout}"))
}

/// Failure: exit 1, stderr is exactly one JSON line `{"error":{...}}`.
fn err_json(out: Output) -> Value {
    assert_eq!(
        out.status.code(),
        Some(1),
        "a failure must exit 1; {}",
        describe(&out)
    );
    let stderr = String::from_utf8(out.stderr.clone()).expect("utf8 stderr");
    let line = stderr.strip_suffix('\n').unwrap_or(&stderr);
    assert!(
        !line.is_empty() && !line.contains('\n'),
        "stderr must be exactly one line; {}",
        describe(&out)
    );
    let v: Value = serde_json::from_str(line)
        .unwrap_or_else(|e| panic!("stderr is not JSON ({e}); {}", describe(&out)));
    assert_eq!(
        v.as_object().unwrap().keys().collect::<Vec<_>>(),
        vec!["error"],
        "top level holds only `error`: {v}"
    );
    assert!(
        v["error"]["message"].is_string(),
        "message is a string: {v}"
    );
    assert!(
        out.stdout.is_empty(),
        "a failure prints nothing on stdout; {}",
        describe(&out)
    );
    v["error"].clone()
}

fn keys(v: &Value) -> BTreeSet<String> {
    v.as_object()
        .unwrap_or_else(|| panic!("expected an object: {v}"))
        .keys()
        .cloned()
        .collect()
}

fn set(items: &[&str]) -> BTreeSet<String> {
    items.iter().map(|s| s.to_string()).collect()
}

fn init_vault() -> (TempDir, String) {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("vault").to_str().unwrap().to_string();
    let out = run(&["init", &path]);
    assert!(out.status.success(), "{}", describe(&out));
    (dir, path)
}

fn vault_id(path: &str) -> String {
    let manifest = std::fs::read(format!("{path}/manifest.json")).unwrap();
    let v: Value = serde_json::from_slice(&manifest).unwrap();
    v["vault_id"].as_str().unwrap().to_string()
}

fn get(path: &str, key: &str) -> Output {
    run(&["settings", "get", "--vault", path, "--key", key])
}

fn set_value(path: &str, key: &str, value: &str) -> Output {
    run(&[
        "settings", "set", "--vault", path, "--key", key, "--value", value,
    ])
}

fn assert_setting_shape(v: &Value, vault: &str, value: i64) {
    assert_eq!(keys(v), set(&["vault_id", "key", "value"]), "keys: {v}");
    assert_eq!(v["vault_id"], vault);
    assert_eq!(v["key"], KEY);
    assert!(v["value"].is_i64(), "value is a JSON integer: {v}");
    assert_eq!(v["value"], json!(value));
}

// ---------- AC 12: get / set ----------

#[test]
fn settings_get_on_a_fresh_vault_is_the_default_of_2() {
    let (_dir, path) = init_vault();
    let v = ok_json(get(&path, KEY));
    assert_setting_shape(&v, &vault_id(&path), 2);
}

#[test]
fn settings_get_prints_vault_id_first() {
    let (_dir, path) = init_vault();
    let out = get(&path, KEY);
    let stdout = String::from_utf8(out.stdout).unwrap();
    assert!(
        stdout.starts_with("{\"vault_id\":\""),
        "vault_id comes first: {stdout}"
    );
}

#[test]
fn settings_set_prints_the_new_value_and_a_later_get_returns_it() {
    let (_dir, path) = init_vault();
    let v = ok_json(set_value(&path, KEY, "3"));
    assert_setting_shape(&v, &vault_id(&path), 3);
    let v = ok_json(get(&path, KEY));
    assert_setting_shape(&v, &vault_id(&path), 3);
}

#[test]
fn settings_set_accepts_both_ends_of_the_range() {
    let (_dir, path) = init_vault();
    for n in [1, 5, 4, 2] {
        let v = ok_json(set_value(&path, KEY, &n.to_string()));
        assert_setting_shape(&v, &vault_id(&path), n);
        let v = ok_json(get(&path, KEY));
        assert_setting_shape(&v, &vault_id(&path), n);
    }
}

// ---------- AC 13: setting_invalid ----------

#[test]
fn settings_set_out_of_range_or_malformed_values_are_setting_invalid() {
    let (_dir, path) = init_vault();
    for bad in ["0", "6", "two", "-1", "2.5", "", "100"] {
        let e = err_json(set_value(&path, KEY, bad));
        assert_eq!(e["code"], "setting_invalid", "value {bad:?}: {e}");
    }
    // None of the rejected values changed the stored setting.
    let v = ok_json(get(&path, KEY));
    assert_setting_shape(&v, &vault_id(&path), 2);
}

#[test]
fn settings_set_a_rejected_value_keeps_the_previous_one() {
    let (_dir, path) = init_vault();
    ok_json(set_value(&path, KEY, "4"));
    let e = err_json(set_value(&path, KEY, "6"));
    assert_eq!(e["code"], "setting_invalid");
    assert_setting_shape(&ok_json(get(&path, KEY)), &vault_id(&path), 4);
}

#[test]
fn settings_set_with_an_unknown_key_is_setting_invalid() {
    let (_dir, path) = init_vault();
    let e = err_json(set_value(&path, "theme", "3"));
    assert_eq!(e["code"], "setting_invalid");
}

#[test]
fn settings_get_with_an_unknown_key_is_setting_invalid() {
    let (_dir, path) = init_vault();
    let e = err_json(get(&path, "theme"));
    assert_eq!(e["code"], "setting_invalid");
}

#[test]
fn settings_set_changes_the_depth_limit_folder_new_enforces() {
    let (_dir, path) = init_vault();
    let new_folder = |name: &str, parent: Option<&str>| -> Output {
        let mut args = vec!["folder", "new", "--vault", path.as_str(), "--name", name];
        if let Some(p) = parent {
            args.extend(["--parent-id", p]);
        }
        run(&args)
    };
    let a = ok_json(new_folder("A", None));
    let b = ok_json(new_folder("B", a["id"].as_str()));
    let refused = err_json(new_folder("C", b["id"].as_str()));
    assert_eq!(refused["code"], "depth_exceeded");

    ok_json(set_value(&path, KEY, "3"));
    let c = ok_json(new_folder("C", b["id"].as_str()));
    assert_eq!(c["depth"], json!(3));
}

// ---------- AC 14: V4 vault migrates on get ----------

const V5_TABLES: [&str; 8] = [
    "agent_changes",
    "blocks",
    "day_review_blocks",
    "day_reviews",
    "footer_chips",
    "smart_folder_members",
    "smart_folders",
    "vault_settings",
];

/// Turns a freshly initialised (V5) vault back into a V4 one: drops every
/// table V5 adds, rewinds `schema_version`, and rewrites the manifest.
fn downgrade_to_v4(path: &str) {
    let conn = Connection::open(format!("{path}/memex.db")).unwrap();
    conn.pragma_update(None, "foreign_keys", "OFF").unwrap();
    conn.execute_batch("DROP INDEX IF EXISTS idx_notes_daily_title;")
        .unwrap();
    for table in V5_TABLES {
        conn.execute_batch(&format!("DROP TABLE IF EXISTS {table};"))
            .unwrap();
    }
    conn.execute("DELETE FROM schema_version WHERE version = 5", [])
        .unwrap();
    drop(conn);

    let manifest_path = format!("{path}/manifest.json");
    let mut manifest: Value =
        serde_json::from_slice(&std::fs::read(&manifest_path).unwrap()).expect("manifest is JSON");
    manifest["schema_version"] = json!(4);
    std::fs::write(
        &manifest_path,
        serde_json::to_vec_pretty(&manifest).unwrap(),
    )
    .unwrap();
}

fn table_exists(conn: &Connection, name: &str) -> bool {
    conn.query_row(
        "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = ?",
        [name],
        |r| r.get::<_, i64>(0),
    )
    .unwrap()
        == 1
}

#[test]
fn settings_get_against_a_v4_vault_migrates_it_to_v5_and_prints_2() {
    let (_dir, path) = init_vault();
    let id = vault_id(&path);
    downgrade_to_v4(&path);

    // The fixture really is V4 before the call.
    {
        let conn = Connection::open(format!("{path}/memex.db")).unwrap();
        assert_eq!(schema::current_version(&conn).unwrap(), 4);
        assert!(!table_exists(&conn, "vault_settings"));
        assert!(!table_exists(&conn, "smart_folders"));
    }

    let v = ok_json(get(&path, KEY));
    assert_setting_shape(&v, &id, 2);

    let conn = Connection::open(format!("{path}/memex.db")).unwrap();
    assert_eq!(schema::current_version(&conn).unwrap(), 5);
    for table in V5_TABLES {
        assert!(table_exists(&conn, table), "{table} exists after migration");
    }
    let manifest: Value =
        serde_json::from_slice(&std::fs::read(format!("{path}/manifest.json")).unwrap()).unwrap();
    assert_eq!(manifest["schema_version"], json!(5));
    assert_eq!(manifest["vault_id"], id.as_str());
}

#[test]
fn settings_set_against_a_v4_vault_migrates_it_and_stores_the_value() {
    let (_dir, path) = init_vault();
    downgrade_to_v4(&path);
    let v = ok_json(set_value(&path, KEY, "4"));
    assert_setting_shape(&v, &vault_id(&path), 4);
    let conn = Connection::open(format!("{path}/memex.db")).unwrap();
    assert_eq!(schema::current_version(&conn).unwrap(), 5);
    assert_setting_shape(&ok_json(get(&path, KEY)), &vault_id(&path), 4);
}

#[test]
fn settings_get_against_a_v4_vault_reaches_folder_commands_too() {
    let (_dir, path) = init_vault();
    downgrade_to_v4(&path);
    ok_json(get(&path, KEY));
    let out = run(&["folder", "new", "--vault", &path, "--name", "Games"]);
    let f = ok_json(out);
    assert_eq!(f["depth"], json!(1));
}
