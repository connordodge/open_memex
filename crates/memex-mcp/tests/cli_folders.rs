//! WI #14 (R11): `memex folder ls|new|update|rm|add|remove` (CONTRACTS C2.5
//! to C2.10, error contract C1). Drives the real `memex` binary against temp
//! vaults. Agent-side state is set up through core as `Caller::Agent`.

use std::collections::BTreeSet;
use std::io::Write;
use std::process::{Command, Output, Stdio};

use memex_core::notes::{self, NoteId};
use memex_core::smart_folders as sf;
use memex_core::{Caller, SystemClock, Vault};
use regex::Regex;
use serde_json::{json, Value};
use tempfile::TempDir;

/// A well-formed ULID that no test vault contains.
const ABSENT_ULID: &str = "01J9Z8Y7X6W5V4T3S2R1Q0P9N8";

const FOLDER_KEYS: [&str; 8] = [
    "vault_id",
    "id",
    "name",
    "parent_id",
    "pinned",
    "depth",
    "created_at",
    "updated_at",
];

fn run(args: &[&str], stdin_body: Option<&str>) -> Output {
    let mut cmd = Command::new(env!("CARGO_BIN_EXE_memex"));
    cmd.args(args);
    cmd.stdin(Stdio::piped());
    cmd.stdout(Stdio::piped());
    cmd.stderr(Stdio::piped());
    let mut child = cmd.spawn().expect("spawn memex");
    if let Some(body) = stdin_body {
        child
            .stdin
            .as_mut()
            .expect("stdin")
            .write_all(body.as_bytes())
            .expect("write stdin");
    }
    drop(child.stdin.take());
    child.wait_with_output().expect("wait")
}

fn describe(out: &Output) -> String {
    format!(
        "exit={:?}\nstdout={}\nstderr={}",
        out.status.code(),
        String::from_utf8_lossy(&out.stdout),
        String::from_utf8_lossy(&out.stderr)
    )
}

/// Success: exit 0, stdout is exactly one line of JSON; returns it parsed.
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

fn ok_stdout(out: Output) -> String {
    assert!(
        out.status.success(),
        "expected success, got {}",
        describe(&out)
    );
    String::from_utf8(out.stdout).expect("utf8 stdout")
}

/// Failure: exit 1, stderr is exactly one JSON line `{"error":{...}}`;
/// returns the `error` object.
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

fn is_ulid(v: &Value) -> bool {
    let re = Regex::new(r"^[0-9A-HJKMNP-TV-Z]{26}$").unwrap();
    v.as_str().is_some_and(|s| re.is_match(s))
}

struct TestVault {
    _dir: TempDir,
    path: String,
}

impl TestVault {
    fn new() -> Self {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("vault").to_str().unwrap().to_string();
        ok_stdout(run(&["init", &path], None));
        Self { _dir: dir, path }
    }

    fn vault_id(&self) -> String {
        let manifest = std::fs::read(format!("{}/manifest.json", self.path)).unwrap();
        let v: Value = serde_json::from_slice(&manifest).unwrap();
        v["vault_id"].as_str().unwrap().to_string()
    }

    fn cli(&self, group: &str, sub: &str, extra: &[&str]) -> Output {
        let mut args = vec![group, sub, "--vault", self.path.as_str()];
        args.extend_from_slice(extra);
        run(&args, None)
    }

    fn folder(&self, sub: &str, extra: &[&str]) -> Output {
        self.cli("folder", sub, extra)
    }

    /// `memex folder new`, asserting success; returns the folder object.
    fn new_folder(&self, name: &str, parent: Option<&str>) -> Value {
        let mut extra = vec!["--name", name];
        if let Some(p) = parent {
            extra.push("--parent-id");
            extra.push(p);
        }
        ok_json(self.folder("new", &extra))
    }

    fn ls(&self) -> Value {
        ok_json(self.folder("ls", &[]))
    }

    fn ls_folder(&self, id: &str) -> Option<Value> {
        self.ls()["folders"]
            .as_array()
            .unwrap()
            .iter()
            .find(|f| f["id"] == id)
            .cloned()
    }

    /// `memex add` (text stdout, C2.1); returns the note id.
    fn add_note(&self, title: &str, role: Option<&str>) -> String {
        let mut args = vec!["add", "--vault", self.path.as_str(), "--title", title];
        if let Some(r) = role {
            args.push("--role");
            args.push(r);
        }
        let out = ok_stdout(run(&args, Some(&format!("# {title}\n\nBody.\n"))));
        let re = Regex::new(r"note_id:\s*([0-9A-Z]{26})").unwrap();
        re.captures(&out)
            .unwrap_or_else(|| panic!("no note_id in add stdout: {out}"))[1]
            .to_string()
    }

    fn set_max_depth(&self, n: &str) {
        ok_json(self.cli(
            "settings",
            "set",
            &["--key", "smart_folder_max_depth", "--value", n],
        ));
    }

    /// A folder created by the agent (unpinned), through core.
    fn agent_folder(&self, name: &str) -> String {
        let mut vault = Vault::open(&self.path).expect("open vault");
        let folder = sf::create_folder(&mut vault, name, None, Caller::Agent, &SystemClock)
            .expect("agent creates folder");
        assert!(!folder.pinned, "an agent-created folder starts unpinned");
        folder.id
    }

    fn role_of(&self, note_id: &str) -> Option<String> {
        let vault = Vault::open(&self.path).expect("open vault");
        let note = notes::get_note(&vault, &NoteId::parse(note_id).unwrap()).unwrap();
        note.frontmatter
            .get("role")
            .and_then(Value::as_str)
            .map(String::from)
    }

    fn note_version(&self, note_id: &str) -> i64 {
        let vault = Vault::open(&self.path).expect("open vault");
        notes::get_note(&vault, &NoteId::parse(note_id).unwrap())
            .unwrap()
            .version
    }
}

fn assert_folder_shape(f: &Value, vault_id: &str) {
    assert_eq!(keys(f), set(&FOLDER_KEYS), "folder keys: {f}");
    assert_eq!(f["vault_id"], vault_id);
    assert!(is_ulid(&f["id"]), "id is a ULID: {f}");
    assert!(f["name"].is_string());
    assert!(f["parent_id"].is_null() || is_ulid(&f["parent_id"]));
    assert!(f["pinned"].is_boolean());
    assert!(f["depth"].is_i64());
    assert!(f["created_at"].is_i64() && f["created_at"].as_i64().unwrap() > 1_600_000_000_000);
    assert!(f["updated_at"].is_i64());
}

// ---------- AC 1: folder new ----------

#[test]
fn folder_new_prints_the_c2_6_folder_object() {
    let v = TestVault::new();
    let f = v.new_folder("Games", None);
    assert_folder_shape(&f, &v.vault_id());
    assert_eq!(f["name"], "Games");
    assert_eq!(f["pinned"], json!(true));
    assert!(f["parent_id"].is_null());
    assert_eq!(f["depth"], json!(1));
    // `vault_id` is the first key on the wire.
    let out = ok_stdout(v.folder("new", &["--name", "Wire"]));
    assert!(
        out.starts_with("{\"vault_id\":\""),
        "vault_id comes first: {out}"
    );
}

#[test]
fn folder_new_persists_the_folder() {
    let v = TestVault::new();
    let f = v.new_folder("Games", None);
    let listed = v.ls_folder(f["id"].as_str().unwrap()).expect("listed");
    assert_eq!(listed["name"], "Games");
    assert_eq!(listed["pinned"], json!(true));
}

// ---------- AC 2: depth ----------

#[test]
fn folder_new_under_a_parent_has_depth_2() {
    let v = TestVault::new();
    let games = v.new_folder("Games", None);
    let gid = games["id"].as_str().unwrap();
    let mech = v.new_folder("Mechanics", Some(gid));
    assert_folder_shape(&mech, &v.vault_id());
    assert_eq!(mech["depth"], json!(2));
    assert_eq!(mech["parent_id"], games["id"]);
    assert_eq!(mech["pinned"], json!(true));
}

#[test]
fn folder_new_third_level_exceeds_the_default_depth() {
    let v = TestVault::new();
    let games = v.new_folder("Games", None);
    let mech = v.new_folder("Mechanics", Some(games["id"].as_str().unwrap()));
    let out = v.folder(
        "new",
        &[
            "--name",
            "Combat",
            "--parent-id",
            mech["id"].as_str().unwrap(),
        ],
    );
    let e = err_json(out);
    assert_eq!(e["code"], "depth_exceeded");
    assert_eq!(e["max_depth"], json!(2));
    assert_eq!(e["required_depth"], json!(3));
    assert_eq!(
        v.ls()["folders"].as_array().unwrap().len(),
        2,
        "no folder added"
    );
}

#[test]
fn folder_new_respects_a_raised_max_depth_and_stops_at_it() {
    let v = TestVault::new();
    v.set_max_depth("3");
    let a = v.new_folder("A", None);
    let b = v.new_folder("B", Some(a["id"].as_str().unwrap()));
    let c = v.new_folder("C", Some(b["id"].as_str().unwrap()));
    assert_eq!(c["depth"], json!(3));
    let e = err_json(v.folder(
        "new",
        &["--name", "D", "--parent-id", c["id"].as_str().unwrap()],
    ));
    assert_eq!(e["code"], "depth_exceeded");
    assert_eq!(e["max_depth"], json!(3));
    assert_eq!(e["required_depth"], json!(4));
}

#[test]
fn folder_new_with_unknown_parent_is_not_found() {
    let v = TestVault::new();
    let e = err_json(v.folder("new", &["--name", "X", "--parent-id", ABSENT_ULID]));
    assert_eq!(e["code"], "not_found");
}

// ---------- AC 3: name conflict ----------

#[test]
fn folder_new_sibling_name_differing_only_in_case_is_name_conflict() {
    let v = TestVault::new();
    v.new_folder("Games", None);
    let e = err_json(v.folder("new", &["--name", "gAmEs"]));
    assert_eq!(e["code"], "name_conflict");
    assert_eq!(v.ls()["folders"].as_array().unwrap().len(), 1);
}

#[test]
fn folder_new_same_name_under_a_different_parent_is_allowed() {
    let v = TestVault::new();
    let games = v.new_folder("Games", None);
    let f = v.new_folder("Games", Some(games["id"].as_str().unwrap()));
    assert_eq!(f["depth"], json!(2));
    // And a conflicting sibling under that parent is still refused.
    let e = err_json(v.folder(
        "new",
        &[
            "--name",
            "GAMES",
            "--parent-id",
            games["id"].as_str().unwrap(),
        ],
    ));
    assert_eq!(e["code"], "name_conflict");
}

// ---------- AC 4: folder ls ----------

#[test]
fn folder_ls_on_a_fresh_vault_is_empty_with_default_max_depth() {
    let v = TestVault::new();
    let ls = v.ls();
    assert_eq!(
        keys(&ls),
        set(&["vault_id", "max_depth", "folders", "unsorted"])
    );
    assert_eq!(ls["vault_id"], v.vault_id());
    assert_eq!(ls["max_depth"], json!(2));
    assert_eq!(ls["folders"], json!([]));
    assert_eq!(ls["unsorted"], json!([]));
}

#[test]
fn folder_ls_prints_the_c2_5_shape() {
    let v = TestVault::new();
    let games = v.new_folder("Games", None);
    let gid = games["id"].as_str().unwrap();
    let mech = v.new_folder("Mechanics", Some(gid));
    let loop_note = v.add_note("Player Loop", Some("topic"));
    let other = v.add_note("Combat Notes", Some("topic"));
    let old = v.add_note("Old note", None);
    ok_json(v.folder(
        "add",
        &["--id", gid, "--note-id", &loop_note, "--pinned", "false"],
    ));
    ok_json(v.folder(
        "add",
        &["--id", mech["id"].as_str().unwrap(), "--note-id", &other],
    ));

    let ls = v.ls();
    assert_eq!(
        keys(&ls),
        set(&["vault_id", "max_depth", "folders", "unsorted"])
    );
    assert_eq!(ls["vault_id"], v.vault_id());
    assert_eq!(ls["max_depth"], json!(2));

    let folders = ls["folders"].as_array().unwrap();
    assert_eq!(folders.len(), 2, "flat list: {ls}");
    for f in folders {
        assert_eq!(
            keys(f),
            set(&[
                "id",
                "name",
                "parent_id",
                "pinned",
                "depth",
                "created_at",
                "updated_at",
                "members"
            ]),
            "folder keys (no vault_id inside the list): {f}"
        );
        assert!(f["created_at"].is_i64() && f["updated_at"].is_i64());
        for m in f["members"].as_array().unwrap() {
            assert_eq!(keys(m), set(&["note_id", "title", "pinned"]), "member: {m}");
        }
    }
    let g = v.ls_folder(gid).expect("Games listed");
    assert_eq!(g["name"], "Games");
    assert!(g["parent_id"].is_null());
    assert_eq!(g["depth"], json!(1));
    assert_eq!(g["pinned"], json!(true));
    assert_eq!(
        g["members"],
        json!([{"note_id": loop_note, "title": "Player Loop", "pinned": false}])
    );
    let m = v
        .ls_folder(mech["id"].as_str().unwrap())
        .expect("Mechanics listed");
    assert_eq!(m["parent_id"], games["id"]);
    assert_eq!(m["depth"], json!(2));
    assert_eq!(
        m["members"],
        json!([{"note_id": other, "title": "Combat Notes", "pinned": true}])
    );

    assert_eq!(
        ls["unsorted"],
        json!([{"note_id": old, "title": "Old note"}])
    );
}

#[test]
fn folder_ls_unsorted_excludes_daily_notes_and_members_and_follows_removal() {
    let v = TestVault::new();
    let f = v.new_folder("Games", None);
    let fid = f["id"].as_str().unwrap();
    let daily = v.add_note("2026-10-03", Some("daily"));
    let member = v.add_note("Member", Some("topic"));
    let loose = v.add_note("Loose", None);
    ok_json(v.folder("add", &["--id", fid, "--note-id", &member]));

    let unsorted = |v: &TestVault| -> BTreeSet<String> {
        v.ls()["unsorted"]
            .as_array()
            .unwrap()
            .iter()
            .map(|n| n["note_id"].as_str().unwrap().to_string())
            .collect()
    };
    assert_eq!(unsorted(&v), BTreeSet::from([loose.clone()]));
    assert!(!unsorted(&v).contains(&daily));

    ok_json(v.folder("remove", &["--id", fid, "--note-id", &member]));
    assert_eq!(unsorted(&v), BTreeSet::from([loose, member]));
}

#[test]
fn folder_ls_reports_the_current_max_depth() {
    let v = TestVault::new();
    v.set_max_depth("4");
    assert_eq!(v.ls()["max_depth"], json!(4));
}

// ---------- AC 5: update rename pins ----------

#[test]
fn folder_update_rename_on_an_agent_folder_pins_it() {
    let v = TestVault::new();
    let id = v.agent_folder("Games");
    let f = ok_json(v.folder("update", &["--id", &id, "--name", "Play"]));
    assert_folder_shape(&f, &v.vault_id());
    assert_eq!(f["id"], id.as_str());
    assert_eq!(f["name"], "Play");
    assert_eq!(f["pinned"], json!(true));
    assert_eq!(f["depth"], json!(1));
    assert!(f["parent_id"].is_null());
    assert_eq!(v.ls_folder(&id).unwrap()["name"], "Play");
}

#[test]
fn folder_update_rename_with_pinned_false_stays_unpinned() {
    let v = TestVault::new();
    let id = v.agent_folder("Games");
    let f = ok_json(v.folder(
        "update",
        &["--id", &id, "--name", "Play", "--pinned", "false"],
    ));
    assert_eq!(f["name"], "Play");
    assert_eq!(f["pinned"], json!(false));
    assert_eq!(v.ls_folder(&id).unwrap()["pinned"], json!(false));
}

#[test]
fn folder_update_rename_with_pinned_false_unpins_a_pinned_folder() {
    let v = TestVault::new();
    let f = v.new_folder("Games", None);
    assert_eq!(f["pinned"], json!(true));
    let id = f["id"].as_str().unwrap();
    let f = ok_json(v.folder(
        "update",
        &["--id", id, "--name", "Play", "--pinned", "false"],
    ));
    assert_eq!(f["pinned"], json!(false));
}

#[test]
fn folder_update_pinned_alone_toggles_the_pin_without_renaming() {
    let v = TestVault::new();
    let f = v.new_folder("Games", None);
    let id = f["id"].as_str().unwrap();
    let off = ok_json(v.folder("update", &["--id", id, "--pinned", "false"]));
    assert_eq!(off["pinned"], json!(false));
    assert_eq!(off["name"], "Games");
    let on = ok_json(v.folder("update", &["--id", id, "--pinned", "true"]));
    assert_eq!(on["pinned"], json!(true));
    assert_eq!(on["name"], "Games");
}

#[test]
fn folder_update_rename_to_a_sibling_name_is_name_conflict() {
    let v = TestVault::new();
    v.new_folder("Games", None);
    let other = v.new_folder("Books", None);
    let e = err_json(v.folder(
        "update",
        &["--id", other["id"].as_str().unwrap(), "--name", "games"],
    ));
    assert_eq!(e["code"], "name_conflict");
    assert_eq!(
        v.ls_folder(other["id"].as_str().unwrap()).unwrap()["name"],
        "Books"
    );
}

#[test]
fn folder_update_unknown_id_is_not_found() {
    let v = TestVault::new();
    let e = err_json(v.folder("update", &["--id", ABSENT_ULID, "--name", "X"]));
    assert_eq!(e["code"], "not_found");
}

// ---------- AC 6: re-parent, to-root, cycle ----------

#[test]
fn folder_update_reparent_pins_and_sets_the_parent_and_depth() {
    let v = TestVault::new();
    let games = v.new_folder("Games", None);
    let id = v.agent_folder("Loose");
    let f = ok_json(v.folder(
        "update",
        &["--id", &id, "--parent-id", games["id"].as_str().unwrap()],
    ));
    assert_folder_shape(&f, &v.vault_id());
    assert_eq!(f["parent_id"], games["id"]);
    assert_eq!(f["depth"], json!(2));
    assert_eq!(f["pinned"], json!(true), "a person re-parent pins (Req 41)");
}

#[test]
fn folder_update_reparent_with_pinned_false_stays_unpinned() {
    let v = TestVault::new();
    let games = v.new_folder("Games", None);
    let id = v.agent_folder("Loose");
    let f = ok_json(v.folder(
        "update",
        &[
            "--id",
            &id,
            "--parent-id",
            games["id"].as_str().unwrap(),
            "--pinned",
            "false",
        ],
    ));
    assert_eq!(f["parent_id"], games["id"]);
    assert_eq!(f["pinned"], json!(false));
}

#[test]
fn folder_update_to_root_moves_a_child_to_the_top_level() {
    let v = TestVault::new();
    let games = v.new_folder("Games", None);
    let mech = v.new_folder("Mechanics", Some(games["id"].as_str().unwrap()));
    let f = ok_json(v.folder(
        "update",
        &["--id", mech["id"].as_str().unwrap(), "--to-root"],
    ));
    assert_folder_shape(&f, &v.vault_id());
    assert!(f["parent_id"].is_null());
    assert_eq!(f["depth"], json!(1));
    assert_eq!(f["pinned"], json!(true));
    let listed = v.ls_folder(mech["id"].as_str().unwrap()).unwrap();
    assert!(listed["parent_id"].is_null());
    assert_eq!(listed["depth"], json!(1));
}

#[test]
fn folder_update_parent_under_its_own_child_is_folder_cycle() {
    let v = TestVault::new();
    let games = v.new_folder("Games", None);
    let gid = games["id"].as_str().unwrap();
    let mech = v.new_folder("Mechanics", Some(gid));
    let e = err_json(v.folder(
        "update",
        &["--id", gid, "--parent-id", mech["id"].as_str().unwrap()],
    ));
    assert_eq!(e["code"], "folder_cycle");
    assert!(v.ls_folder(gid).unwrap()["parent_id"].is_null());
}

#[test]
fn folder_update_parent_under_itself_is_folder_cycle() {
    let v = TestVault::new();
    let games = v.new_folder("Games", None);
    let gid = games["id"].as_str().unwrap();
    let e = err_json(v.folder("update", &["--id", gid, "--parent-id", gid]));
    assert_eq!(e["code"], "folder_cycle");
}

#[test]
fn folder_update_reparent_beyond_the_max_depth_is_depth_exceeded() {
    let v = TestVault::new();
    let games = v.new_folder("Games", None);
    let mech = v.new_folder("Mechanics", Some(games["id"].as_str().unwrap()));
    let loose = v.new_folder("Loose", None);
    let e = err_json(v.folder(
        "update",
        &[
            "--id",
            loose["id"].as_str().unwrap(),
            "--parent-id",
            mech["id"].as_str().unwrap(),
        ],
    ));
    assert_eq!(e["code"], "depth_exceeded");
    assert_eq!(e["max_depth"], json!(2));
    assert_eq!(e["required_depth"], json!(3));
}

#[test]
fn folder_update_parent_id_and_to_root_conflict_is_a_usage_error() {
    let v = TestVault::new();
    let games = v.new_folder("Games", None);
    let gid = games["id"].as_str().unwrap();
    let out = v.folder("update", &["--id", gid, "--parent-id", gid, "--to-root"]);
    assert_eq!(out.status.code(), Some(2), "{}", describe(&out));
}

#[test]
fn folder_update_pinned_must_be_true_or_false() {
    let v = TestVault::new();
    let games = v.new_folder("Games", None);
    let out = v.folder(
        "update",
        &["--id", games["id"].as_str().unwrap(), "--pinned", "maybe"],
    );
    assert_eq!(out.status.code(), Some(2), "{}", describe(&out));
}

// ---------- AC 7: rm ----------

#[test]
fn folder_rm_prints_the_c2_8_shape_and_removes_the_folder() {
    let v = TestVault::new();
    let f = v.new_folder("Games", None);
    let id = f["id"].as_str().unwrap();
    let out = ok_json(v.folder("rm", &["--id", id]));
    assert_eq!(keys(&out), set(&["vault_id", "id", "deleted"]));
    assert_eq!(out["vault_id"], v.vault_id());
    assert_eq!(out["id"], id);
    assert_eq!(out["deleted"], json!(true));
    assert!(v.ls_folder(id).is_none());
    assert_eq!(v.ls()["folders"], json!([]));
}

#[test]
fn folder_rm_reparents_subfolders_to_the_former_parent() {
    let v = TestVault::new();
    v.set_max_depth("3");
    let a = v.new_folder("A", None);
    let b = v.new_folder("B", Some(a["id"].as_str().unwrap()));
    let c = v.new_folder("C", Some(b["id"].as_str().unwrap()));
    ok_json(v.folder("rm", &["--id", b["id"].as_str().unwrap()]));
    assert!(v.ls_folder(b["id"].as_str().unwrap()).is_none());
    let c_now = v.ls_folder(c["id"].as_str().unwrap()).expect("C survives");
    assert_eq!(c_now["parent_id"], a["id"]);
    assert_eq!(c_now["depth"], json!(2));
}

#[test]
fn folder_rm_of_a_root_folder_promotes_its_children_to_root() {
    let v = TestVault::new();
    let games = v.new_folder("Games", None);
    let mech = v.new_folder("Mechanics", Some(games["id"].as_str().unwrap()));
    ok_json(v.folder("rm", &["--id", games["id"].as_str().unwrap()]));
    let m = v
        .ls_folder(mech["id"].as_str().unwrap())
        .expect("child survives");
    assert!(m["parent_id"].is_null());
    assert_eq!(m["depth"], json!(1));
}

#[test]
fn folder_rm_keeps_the_notes_which_become_unsorted() {
    let v = TestVault::new();
    let f = v.new_folder("Games", None);
    let fid = f["id"].as_str().unwrap();
    let note = v.add_note("Topic", Some("topic"));
    ok_json(v.folder("add", &["--id", fid, "--note-id", &note]));
    ok_json(v.folder("rm", &["--id", fid]));
    assert_eq!(
        v.ls()["unsorted"],
        json!([{"note_id": note, "title": "Topic"}])
    );
}

#[test]
fn folder_rm_unknown_id_is_not_found() {
    let v = TestVault::new();
    let e = err_json(v.folder("rm", &["--id", ABSENT_ULID]));
    assert_eq!(e["code"], "not_found");
}

// ---------- AC 8: add ----------

#[test]
fn folder_add_topic_note_prints_the_c2_9_shape_pinned_by_default() {
    let v = TestVault::new();
    let f = v.new_folder("Games", None);
    let fid = f["id"].as_str().unwrap();
    let note = v.add_note("Player Loop", Some("topic"));
    let m = ok_json(v.folder("add", &["--id", fid, "--note-id", &note]));
    assert_eq!(
        keys(&m),
        set(&[
            "vault_id",
            "smart_folder_id",
            "note_id",
            "pinned",
            "role_set"
        ])
    );
    assert_eq!(m["vault_id"], v.vault_id());
    assert_eq!(m["smart_folder_id"], fid);
    assert_eq!(m["note_id"], note.as_str());
    assert_eq!(m["pinned"], json!(true));
    assert_eq!(m["role_set"], json!(false));
    let listed = v.ls_folder(fid).unwrap();
    assert_eq!(
        listed["members"],
        json!([{"note_id": note, "title": "Player Loop", "pinned": true}])
    );
}

#[test]
fn folder_add_pinned_false_updates_the_membership_and_is_idempotent() {
    let v = TestVault::new();
    let f = v.new_folder("Games", None);
    let fid = f["id"].as_str().unwrap();
    let note = v.add_note("Player Loop", Some("topic"));
    ok_json(v.folder("add", &["--id", fid, "--note-id", &note]));

    let m = ok_json(v.folder(
        "add",
        &["--id", fid, "--note-id", &note, "--pinned", "false"],
    ));
    assert_eq!(m["pinned"], json!(false));
    assert_eq!(m["role_set"], json!(false));
    let members = v.ls_folder(fid).unwrap()["members"].clone();
    assert_eq!(members.as_array().unwrap().len(), 1, "no duplicate member");
    assert_eq!(members[0]["pinned"], json!(false));

    // And back: the same pair toggles pinned on again.
    let m = ok_json(v.folder(
        "add",
        &["--id", fid, "--note-id", &note, "--pinned", "true"],
    ));
    assert_eq!(m["pinned"], json!(true));
    assert_eq!(
        v.ls_folder(fid).unwrap()["members"][0]["pinned"],
        json!(true)
    );

    // Re-adding with no flag pins (the default), still one member.
    ok_json(v.folder(
        "add",
        &["--id", fid, "--note-id", &note, "--pinned", "false"],
    ));
    let m = ok_json(v.folder("add", &["--id", fid, "--note-id", &note]));
    assert_eq!(m["pinned"], json!(true));
    assert_eq!(
        v.ls_folder(fid).unwrap()["members"]
            .as_array()
            .unwrap()
            .len(),
        1
    );
}

#[test]
fn folder_add_pinned_must_be_true_or_false() {
    let v = TestVault::new();
    let f = v.new_folder("Games", None);
    let note = v.add_note("Player Loop", Some("topic"));
    let out = v.folder(
        "add",
        &[
            "--id",
            f["id"].as_str().unwrap(),
            "--note-id",
            &note,
            "--pinned",
            "yes",
        ],
    );
    assert_eq!(out.status.code(), Some(2), "{}", describe(&out));
}

#[test]
fn folder_add_one_note_to_two_folders() {
    let v = TestVault::new();
    let a = v.new_folder("A", None);
    let b = v.new_folder("B", None);
    let note = v.add_note("Shared", Some("topic"));
    ok_json(v.folder(
        "add",
        &["--id", a["id"].as_str().unwrap(), "--note-id", &note],
    ));
    ok_json(v.folder(
        "add",
        &["--id", b["id"].as_str().unwrap(), "--note-id", &note],
    ));
    for f in [&a, &b] {
        assert_eq!(
            v.ls_folder(f["id"].as_str().unwrap()).unwrap()["members"]
                .as_array()
                .unwrap()
                .len(),
            1
        );
    }
}

// ---------- AC 9: add adopts a role-less note ----------

#[test]
fn folder_add_role_less_note_sets_role_topic() {
    let v = TestVault::new();
    let f = v.new_folder("Games", None);
    let fid = f["id"].as_str().unwrap();
    let note = v.add_note("Old note", None);
    assert_eq!(v.role_of(&note), None, "fixture note has no role");
    let before = v.note_version(&note);

    let m = ok_json(v.folder("add", &["--id", fid, "--note-id", &note]));
    assert_eq!(m["role_set"], json!(true));
    assert_eq!(m["pinned"], json!(true));
    assert_eq!(v.role_of(&note).as_deref(), Some("topic"));
    assert!(
        v.note_version(&note) > before,
        "the role change is a versioned write"
    );

    // A second add finds the role already set.
    let again = ok_json(v.folder("add", &["--id", fid, "--note-id", &note]));
    assert_eq!(again["role_set"], json!(false));
}

#[test]
fn folder_add_topic_note_leaves_its_version_alone() {
    let v = TestVault::new();
    let f = v.new_folder("Games", None);
    let note = v.add_note("Topic", Some("topic"));
    let before = v.note_version(&note);
    ok_json(v.folder(
        "add",
        &["--id", f["id"].as_str().unwrap(), "--note-id", &note],
    ));
    assert_eq!(v.note_version(&note), before);
    assert_eq!(v.role_of(&note).as_deref(), Some("topic"));
}

// ---------- AC 10: add errors ----------

#[test]
fn folder_add_daily_note_is_role_rule() {
    let v = TestVault::new();
    let f = v.new_folder("Games", None);
    let fid = f["id"].as_str().unwrap();
    let daily = v.add_note("2026-10-03", Some("daily"));
    let e = err_json(v.folder("add", &["--id", fid, "--note-id", &daily]));
    assert_eq!(e["code"], "role_rule");
    assert!(
        e["message"].as_str().unwrap().contains("role"),
        "message mentions the role: {e}"
    );
    assert_eq!(v.ls_folder(fid).unwrap()["members"], json!([]));
    assert_eq!(v.role_of(&daily).as_deref(), Some("daily"));
}

#[test]
fn folder_add_unknown_folder_is_not_found() {
    let v = TestVault::new();
    let note = v.add_note("Topic", Some("topic"));
    let e = err_json(v.folder("add", &["--id", ABSENT_ULID, "--note-id", &note]));
    assert_eq!(e["code"], "not_found");
}

#[test]
fn folder_add_unknown_note_is_not_found() {
    let v = TestVault::new();
    let f = v.new_folder("Games", None);
    let e = err_json(v.folder(
        "add",
        &["--id", f["id"].as_str().unwrap(), "--note-id", ABSENT_ULID],
    ));
    assert_eq!(e["code"], "not_found");
}

// ---------- AC 11: remove ----------

#[test]
fn folder_remove_prints_the_c2_10_shape_and_drops_the_membership() {
    let v = TestVault::new();
    let f = v.new_folder("Games", None);
    let fid = f["id"].as_str().unwrap();
    let note = v.add_note("Player Loop", Some("topic"));
    ok_json(v.folder("add", &["--id", fid, "--note-id", &note]));

    let out = ok_json(v.folder("remove", &["--id", fid, "--note-id", &note]));
    assert_eq!(
        keys(&out),
        set(&["vault_id", "smart_folder_id", "note_id", "removed"])
    );
    assert_eq!(out["vault_id"], v.vault_id());
    assert_eq!(out["smart_folder_id"], fid);
    assert_eq!(out["note_id"], note.as_str());
    assert_eq!(out["removed"], json!(true));
    assert_eq!(v.ls_folder(fid).unwrap()["members"], json!([]));
}

#[test]
fn folder_remove_is_never_blocked_by_pinning() {
    let v = TestVault::new();
    // A pinned folder holding a pinned membership.
    let f = v.new_folder("Games", None);
    assert_eq!(f["pinned"], json!(true));
    let fid = f["id"].as_str().unwrap();
    let note = v.add_note("Player Loop", Some("topic"));
    let m = ok_json(v.folder(
        "add",
        &["--id", fid, "--note-id", &note, "--pinned", "true"],
    ));
    assert_eq!(m["pinned"], json!(true));
    let out = ok_json(v.folder("remove", &["--id", fid, "--note-id", &note]));
    assert_eq!(out["removed"], json!(true));
    assert_eq!(v.ls_folder(fid).unwrap()["members"], json!([]));
}

#[test]
fn folder_remove_of_a_non_member_is_not_found() {
    let v = TestVault::new();
    let f = v.new_folder("Games", None);
    let note = v.add_note("Topic", Some("topic"));
    let e = err_json(v.folder(
        "remove",
        &["--id", f["id"].as_str().unwrap(), "--note-id", &note],
    ));
    assert_eq!(e["code"], "not_found");
}

#[test]
fn folder_remove_unknown_folder_is_not_found() {
    let v = TestVault::new();
    let note = v.add_note("Topic", Some("topic"));
    let e = err_json(v.folder("remove", &["--id", ABSENT_ULID, "--note-id", &note]));
    assert_eq!(e["code"], "not_found");
}
