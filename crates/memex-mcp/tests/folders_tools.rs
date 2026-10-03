//! WI #13 (R10): the Smart Folder and vault-settings MCP tools.
//!
//! Every tool calls core as `Caller::Agent` and returns the C2 shapes;
//! rule failures return the C1 error object (`err_from`). Person-side state
//! (pinned folders and memberships) is set up through core with
//! `Caller::Person`, as the CLI (#14) will.
//!
//! Params are built with `serde_json::from_value(json!(…))`, never struct
//! literals (D23).

use std::collections::BTreeSet;
use std::io::{BufRead, BufReader, Write};
use std::process::{Child, ChildStdin, Command, Stdio};
use std::sync::mpsc::{self, Receiver};
use std::sync::Arc;
use std::time::Duration;

use memex_core::smart_folders as sf;
use memex_core::{vault_settings, Caller, SystemClock, Vault};
use memex_mcp::state::AppState;
use memex_mcp::tools::Memex;
use rmcp::handler::server::wrapper::Parameters;
use serde::de::DeserializeOwned;
use serde_json::{json, Value};
use tempfile::TempDir;

fn fresh() -> (TempDir, Arc<AppState>, Memex) {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("vault");
    let vault = Vault::create(&path).unwrap();
    let state = Arc::new(AppState::new(vault, path, None));
    let memex = Memex::new(state.clone());
    (dir, state, memex)
}

fn params<T: DeserializeOwned>(v: Value) -> Parameters<T> {
    Parameters(serde_json::from_value(v).expect("params deserialize"))
}

fn parse(resp: &str) -> Value {
    serde_json::from_str(resp).unwrap_or_else(|e| panic!("tool returned non-JSON ({e}): {resp}"))
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

fn is_ulid(s: &Value) -> bool {
    let re = regex::Regex::new(r"^[0-9A-HJKMNP-TV-Z]{26}$").unwrap();
    s.as_str().is_some_and(|s| re.is_match(s))
}

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

async fn vault_id(state: &AppState) -> String {
    state.vault.lock().await.vault_id().to_string()
}

// ---------- tool calls ----------

async fn create_folder(m: &Memex, args: Value) -> Value {
    parse(&m.create_smart_folder(params(args)).await)
}

async fn create_folder_ok(m: &Memex, name: &str, parent: Option<&str>) -> String {
    let mut args = json!({ "name": name });
    if let Some(p) = parent {
        args["parent_id"] = json!(p);
    }
    let v = create_folder(m, args).await;
    v["id"]
        .as_str()
        .unwrap_or_else(|| panic!("create_smart_folder failed: {v}"))
        .to_string()
}

async fn update_folder(m: &Memex, args: Value) -> Value {
    parse(&m.update_smart_folder(params(args)).await)
}

async fn delete_folder(m: &Memex, id: &str) -> Value {
    parse(&m.delete_smart_folder(params(json!({ "id": id }))).await)
}

async fn add(m: &Memex, folder: &str, note: &str) -> Value {
    parse(
        &m.add_to_smart_folder(params(json!({
            "topic_note_id": note,
            "smart_folder_id": folder,
        })))
        .await,
    )
}

async fn remove(m: &Memex, folder: &str, note: &str) -> Value {
    parse(
        &m.remove_from_smart_folder(params(json!({
            "topic_note_id": note,
            "smart_folder_id": folder,
        })))
        .await,
    )
}

async fn list(m: &Memex) -> Value {
    parse(&m.list_smart_folders(params(json!({}))).await)
}

async fn settings(m: &Memex) -> Value {
    parse(&m.get_vault_settings(params(json!({}))).await)
}

async fn create_note(m: &Memex, args: Value) -> String {
    let v = parse(&m.create_note(params(args)).await);
    v["note_id"]
        .as_str()
        .unwrap_or_else(|| panic!("create_note failed: {v}"))
        .to_string()
}

async fn topic(m: &Memex, title: &str) -> String {
    create_note(
        m,
        json!({ "title": title, "content_md": format!("{title} notes."), "role": "topic" }),
    )
    .await
}

fn listed<'a>(list: &'a Value, id: &str) -> &'a Value {
    list["folders"]
        .as_array()
        .unwrap_or_else(|| panic!("folders array: {list}"))
        .iter()
        .find(|f| f["id"] == json!(id))
        .unwrap_or_else(|| panic!("folder {id} not listed: {list}"))
}

// ---------- person-side setup through core ----------

async fn person_folder(state: &AppState, name: &str, parent: Option<&str>) -> String {
    let mut v = state.vault.lock().await;
    sf::create_folder(&mut v, name, parent, Caller::Person, &SystemClock)
        .unwrap()
        .id
}

async fn person_add(state: &AppState, folder: &str, note: &str) {
    let mut v = state.vault.lock().await;
    sf::add_member(&mut v, folder, note, None, Caller::Person, None).unwrap();
}

async fn folder_row(state: &AppState, id: &str) -> (String, Option<String>, bool) {
    let v = state.vault.lock().await;
    v.connection_ref()
        .query_row(
            "SELECT name, parent_id, pinned FROM smart_folders WHERE id = ?",
            [id],
            |r| Ok((r.get(0)?, r.get(1)?, r.get::<_, i64>(2)? != 0)),
        )
        .unwrap()
}

async fn membership(state: &AppState, folder: &str, note: &str) -> Option<bool> {
    let v = state.vault.lock().await;
    v.connection_ref()
        .query_row(
            "SELECT pinned FROM smart_folder_members WHERE smart_folder_id = ? AND note_id = ?",
            [folder, note],
            |r| r.get::<_, i64>(0),
        )
        .ok()
        .map(|p| p != 0)
}

// ---------- error assertions ----------

fn error_obj(v: &Value) -> &Value {
    assert!(v["error"].is_object(), "expected an error object, got {v}");
    &v["error"]
}

fn assert_c1(v: &Value, code: &str, extra: &[&str]) {
    let e = error_obj(v);
    assert_eq!(e["code"], json!(code), "{v}");
    assert!(e["message"].is_string(), "message: {v}");
    let mut expected = set(&["code", "message"]);
    expected.extend(set(extra));
    assert_eq!(keys(e), expected, "C1 fields for {code}: {v}");
}

// ======================================================================
// AC 19: the six folder tools act as the agent and return the C2 shapes.
// ======================================================================

#[tokio::test]
async fn mcp_create_smart_folder_returns_the_folder_object_unpinned() {
    let (_d, state, m) = fresh();
    let root = create_folder(&m, json!({ "name": "Games" })).await;
    assert_eq!(keys(&root), set(&FOLDER_KEYS), "{root}");
    assert_eq!(root["vault_id"], json!(vault_id(&state).await));
    assert!(is_ulid(&root["id"]), "{root}");
    assert_eq!(root["name"], json!("Games"));
    assert_eq!(root["parent_id"], Value::Null);
    assert_eq!(
        root["pinned"],
        json!(false),
        "agent-created folders are unpinned"
    );
    assert_eq!(root["depth"], json!(1));
    assert!(root["created_at"].is_i64(), "{root}");
    assert_eq!(root["created_at"], root["updated_at"]);

    let id = root["id"].as_str().unwrap();
    let child = create_folder(&m, json!({ "name": "Platformers", "parent_id": id })).await;
    assert_eq!(keys(&child), set(&FOLDER_KEYS), "{child}");
    assert_eq!(child["parent_id"], json!(id));
    assert_eq!(child["depth"], json!(2));
    assert_eq!(child["pinned"], json!(false));
    let (_, _, pinned) = folder_row(&state, child["id"].as_str().unwrap()).await;
    assert!(!pinned, "stored unpinned");
}

#[tokio::test]
async fn mcp_update_smart_folder_renames_reparents_and_moves_to_root() {
    let (_d, state, m) = fresh();
    let a = create_folder_ok(&m, "Games", None).await;
    let b = create_folder_ok(&m, "Design", None).await;

    let got = update_folder(&m, json!({ "id": b, "name": "Game Design" })).await;
    assert_eq!(keys(&got), set(&FOLDER_KEYS), "{got}");
    assert_eq!(got["name"], json!("Game Design"));
    assert_eq!(got["pinned"], json!(false), "agent edits never pin");

    let got = update_folder(&m, json!({ "id": b, "parent_id": a })).await;
    assert_eq!(keys(&got), set(&FOLDER_KEYS), "{got}");
    assert_eq!(got["parent_id"], json!(a));
    assert_eq!(got["depth"], json!(2));
    assert_eq!(got["name"], json!("Game Design"));

    let got = update_folder(&m, json!({ "id": b, "to_root": true })).await;
    assert_eq!(got["parent_id"], Value::Null, "{got}");
    assert_eq!(got["depth"], json!(1));
    assert_eq!(
        folder_row(&state, &b).await,
        ("Game Design".to_string(), None, false)
    );

    // `to_root: false` is the default and moves nothing.
    let got = update_folder(&m, json!({ "id": b, "name": "GD", "to_root": false })).await;
    assert_eq!(got["parent_id"], Value::Null, "{got}");
    assert_eq!(got["name"], json!("GD"));
}

#[tokio::test]
async fn mcp_delete_smart_folder_returns_the_deleted_shape() {
    let (_d, state, m) = fresh();
    let a = create_folder_ok(&m, "Games", None).await;
    let b = create_folder_ok(&m, "Platformers", Some(&a)).await;
    let got = delete_folder(&m, &a).await;
    assert_eq!(
        got,
        json!({ "vault_id": vault_id(&state).await, "id": a, "deleted": true })
    );
    let l = list(&m).await;
    let ids: BTreeSet<String> = l["folders"]
        .as_array()
        .unwrap()
        .iter()
        .map(|f| f["id"].as_str().unwrap().to_string())
        .collect();
    assert_eq!(ids, BTreeSet::from([b.clone()]));
    assert_eq!(
        listed(&l, &b)["parent_id"],
        Value::Null,
        "child re-parented to root"
    );
}

#[tokio::test]
async fn mcp_add_and_remove_membership_return_their_shapes() {
    let (_d, state, m) = fresh();
    let vid = vault_id(&state).await;
    let f = create_folder_ok(&m, "Games", None).await;
    let n = topic(&m, "Player Loop").await;

    let got = add(&m, &f, &n).await;
    assert_eq!(
        got,
        json!({
            "vault_id": vid,
            "smart_folder_id": f,
            "note_id": n,
            "pinned": false,
            "role_set": false,
        })
    );
    assert_eq!(membership(&state, &f, &n).await, Some(false));

    // Idempotent.
    assert_eq!(add(&m, &f, &n).await, got);

    let got = remove(&m, &f, &n).await;
    assert_eq!(
        got,
        json!({
            "vault_id": vid,
            "smart_folder_id": f,
            "note_id": n,
            "removed": true,
        })
    );
    assert_eq!(membership(&state, &f, &n).await, None);
}

#[tokio::test]
async fn mcp_list_smart_folders_lists_every_folder_with_members_and_unsorted() {
    let (_d, state, m) = fresh();
    let games = person_folder(&state, "Games", None).await;
    let plat = create_folder_ok(&m, "Platformers", Some(&games)).await;
    let design = create_folder_ok(&m, "Design", None).await;
    let pinned_n = topic(&m, "Player Loop").await;
    let agent_n = topic(&m, "Jump Arc").await;
    let lone = topic(&m, "Sleep").await;
    let plain = create_note(&m, json!({ "title": "Old note", "content_md": "Old." })).await;
    create_note(
        &m,
        json!({ "title": "2026-10-01", "content_md": "", "role": "daily" }),
    )
    .await;
    person_add(&state, &plat, &pinned_n).await;
    add(&m, &plat, &agent_n).await;
    add(&m, &games, &agent_n).await;

    let l = list(&m).await;
    assert_eq!(
        keys(&l),
        set(&["vault_id", "max_depth", "folders", "unsorted"]),
        "{l}"
    );
    assert_eq!(l["vault_id"], json!(vault_id(&state).await));
    assert_eq!(l["max_depth"], json!(2));
    assert_eq!(l["folders"].as_array().unwrap().len(), 3, "flat list: {l}");

    let mut listed_keys: Vec<&str> = FOLDER_KEYS[1..].to_vec();
    listed_keys.push("members");
    for f in l["folders"].as_array().unwrap() {
        assert_eq!(keys(f), set(&listed_keys), "listed folder shape: {f}");
        for mem in f["members"].as_array().unwrap() {
            assert_eq!(keys(mem), set(&["note_id", "title", "pinned"]), "{mem}");
        }
    }

    let g = listed(&l, &games);
    assert_eq!(g["name"], json!("Games"));
    assert_eq!(g["parent_id"], Value::Null);
    assert_eq!(g["depth"], json!(1));
    assert_eq!(g["pinned"], json!(true));
    assert_eq!(
        g["members"],
        json!([{ "note_id": agent_n, "title": "Jump Arc", "pinned": false }])
    );

    let p = listed(&l, &plat);
    assert_eq!(p["parent_id"], json!(games));
    assert_eq!(p["depth"], json!(2));
    assert_eq!(p["pinned"], json!(false));
    let members: BTreeSet<(String, String, bool)> = p["members"]
        .as_array()
        .unwrap()
        .iter()
        .map(|x| {
            (
                x["note_id"].as_str().unwrap().to_string(),
                x["title"].as_str().unwrap().to_string(),
                x["pinned"].as_bool().unwrap(),
            )
        })
        .collect();
    assert_eq!(
        members,
        BTreeSet::from([
            (pinned_n.clone(), "Player Loop".to_string(), true),
            (agent_n.clone(), "Jump Arc".to_string(), false),
        ])
    );
    assert_eq!(listed(&l, &design)["members"], json!([]));

    let unsorted: BTreeSet<(String, String)> = l["unsorted"]
        .as_array()
        .unwrap()
        .iter()
        .map(|u| {
            assert_eq!(keys(u), set(&["note_id", "title"]), "{u}");
            (
                u["note_id"].as_str().unwrap().to_string(),
                u["title"].as_str().unwrap().to_string(),
            )
        })
        .collect();
    assert_eq!(
        unsorted,
        BTreeSet::from([(lone, "Sleep".to_string()), (plain, "Old note".to_string()),]),
        "unsorted = non-daily notes with no membership"
    );
}

#[tokio::test]
async fn mcp_folder_tools_act_as_the_agent() {
    let (_d, state, m) = fresh();
    let pinned_f = person_folder(&state, "Games", None).await;
    let open_f = create_folder_ok(&m, "Inbox", None).await;
    let n = topic(&m, "Player Loop").await;

    // Agent rules apply: a pinned folder can gain members but not be renamed.
    let got = add(&m, &pinned_f, &n).await;
    assert_eq!(got["pinned"], json!(false), "{got}");
    let got = update_folder(&m, json!({ "id": pinned_f, "name": "Gaming" })).await;
    assert_eq!(error_obj(&got)["code"], json!("pinned_rule"));
    assert_eq!(folder_row(&state, &pinned_f).await.0, "Games");

    // An agent membership in an unpinned folder can be removed by the agent.
    add(&m, &open_f, &n).await;
    let got = remove(&m, &open_f, &n).await;
    assert_eq!(got["removed"], json!(true), "{got}");
}

#[tokio::test]
async fn mcp_unknown_ids_return_an_error_object() {
    let (_d, _state, m) = fresh();
    let missing = "01J9Z8Y7X6W5V4T3S2R1Q0P9N8";
    let n = topic(&m, "Player Loop").await;
    error_obj(&update_folder(&m, json!({ "id": missing, "name": "X" })).await);
    error_obj(&delete_folder(&m, missing).await);
    error_obj(&add(&m, missing, &n).await);
    error_obj(&create_folder(&m, json!({ "name": "X", "parent_id": missing })).await);
}

// ======================================================================
// AC 20: get_vault_settings returns smart_folder_max_depth and link_kinds.
// ======================================================================

#[tokio::test]
async fn mcp_get_vault_settings_returns_max_depth_and_link_kinds() {
    let (_d, state, m) = fresh();
    create_note(
        &m,
        json!({ "title": "Target", "content_md": "Target body." }),
    )
    .await;
    create_note(
        &m,
        json!({ "title": "Source", "content_md": "See [[Target~inspired-by]] for more." }),
    )
    .await;
    {
        let v = state.vault.lock().await;
        let n: i64 = v
            .connection_ref()
            .query_row(
                "SELECT COUNT(*) FROM links WHERE link_kind = 'inspired-by'",
                [],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(n, 1, "fixture: a user-defined kind is present in links");
    }

    let got = settings(&m).await;
    assert_eq!(
        keys(&got),
        set(&["smart_folder_max_depth", "link_kinds"]),
        "{got}"
    );
    assert_eq!(got["smart_folder_max_depth"], json!(2));
    let kinds: Vec<String> = got["link_kinds"]
        .as_array()
        .unwrap_or_else(|| panic!("link_kinds array: {got}"))
        .iter()
        .map(|k| k.as_str().expect("kind string").to_string())
        .collect();
    let unique: BTreeSet<String> = kinds.iter().cloned().collect();
    assert_eq!(unique.len(), kinds.len(), "no duplicate kinds: {kinds:?}");
    for k in [
        "references",
        "extends",
        "contradicts",
        "example-of",
        "inspired-by",
    ] {
        assert!(unique.contains(k), "link_kinds contains {k}: {kinds:?}");
    }

    {
        let mut v = state.vault.lock().await;
        vault_settings::set_setting(&mut v, "smart_folder_max_depth", "4").unwrap();
    }
    assert_eq!(settings(&m).await["smart_folder_max_depth"], json!(4));
}

#[tokio::test]
async fn mcp_get_vault_settings_lists_built_in_kinds_in_an_empty_vault() {
    let (_d, _state, m) = fresh();
    let got = settings(&m).await;
    let kinds: BTreeSet<String> = got["link_kinds"]
        .as_array()
        .unwrap_or_else(|| panic!("link_kinds array: {got}"))
        .iter()
        .map(|k| k.as_str().unwrap().to_string())
        .collect();
    for k in ["references", "extends", "contradicts", "example-of"] {
        assert!(kinds.contains(k), "{k} in {kinds:?}");
    }
    assert!(!kinds.contains("inspired-by"));
}

// ======================================================================
// AC 21: every rule failure over MCP returns the C1 shape with its fields.
// ======================================================================

#[tokio::test]
async fn mcp_depth_exceeded_returns_c1_with_max_and_required_depth() {
    let (_d, _state, m) = fresh();
    let a = create_folder_ok(&m, "Games", None).await;
    let b = create_folder_ok(&m, "Platformers", Some(&a)).await;
    let got = create_folder(&m, json!({ "name": "Too Deep", "parent_id": b })).await;
    assert_c1(&got, "depth_exceeded", &["max_depth", "required_depth"]);
    assert_eq!(got["error"]["max_depth"], json!(2));
    assert_eq!(got["error"]["required_depth"], json!(3));

    // Moving a height-2 subtree under a depth-1 folder needs depth 3.
    let x = create_folder_ok(&m, "X", None).await;
    let got = update_folder(&m, json!({ "id": a, "parent_id": x })).await;
    assert_c1(&got, "depth_exceeded", &["max_depth", "required_depth"]);
    assert_eq!(got["error"]["required_depth"], json!(3));
}

#[tokio::test]
async fn mcp_pinned_rule_returns_c1_with_the_item() {
    let (_d, state, m) = fresh();
    let games = person_folder(&state, "Games", None).await;
    let other = create_folder_ok(&m, "Work", None).await;
    let n = topic(&m, "Player Loop").await;
    add(&m, &games, &n).await;

    for got in [
        update_folder(&m, json!({ "id": games, "name": "Gaming" })).await,
        update_folder(&m, json!({ "id": games, "parent_id": other })).await,
        delete_folder(&m, &games).await,
    ] {
        assert_c1(&got, "pinned_rule", &["item"]);
        assert_eq!(got["error"]["item"], json!(games));
        assert!(
            got["error"]["message"].as_str().unwrap().contains("Games"),
            "message names the folder: {got}"
        );
    }
    let got = remove(&m, &games, &n).await;
    assert_c1(&got, "pinned_rule", &["item"]);
    assert_eq!(
        folder_row(&state, &games).await,
        ("Games".into(), None, true)
    );
    assert_eq!(membership(&state, &games, &n).await, Some(false));

    // A pinned membership in an unpinned folder.
    let inbox = create_folder_ok(&m, "Inbox", None).await;
    person_add(&state, &inbox, &n).await;
    let got = remove(&m, &inbox, &n).await;
    assert_c1(&got, "pinned_rule", &["item"]);
    assert_eq!(got["error"]["item"], json!(format!("{inbox}/{n}")));
    assert!(
        got["error"]["message"]
            .as_str()
            .unwrap()
            .contains("Player Loop"),
        "message names the membership's note: {got}"
    );
    let got = delete_folder(&m, &inbox).await;
    assert_c1(&got, "pinned_rule", &["item"]);
    assert_eq!(membership(&state, &inbox, &n).await, Some(true));
}

#[tokio::test]
async fn mcp_name_conflict_and_folder_cycle_return_c1() {
    let (_d, _state, m) = fresh();
    create_folder_ok(&m, "Café", None).await;
    let got = create_folder(&m, json!({ "name": "CAFÉ" })).await;
    assert_c1(&got, "name_conflict", &[]);

    let x = create_folder_ok(&m, "X", None).await;
    let y = create_folder_ok(&m, "Y", Some(&x)).await;
    let got = update_folder(&m, json!({ "id": x, "parent_id": x })).await;
    assert_c1(&got, "folder_cycle", &[]);
    let got = update_folder(&m, json!({ "id": x, "parent_id": y })).await;
    assert_c1(&got, "folder_cycle", &[]);
}

#[tokio::test]
async fn mcp_role_rule_returns_c1_for_roleless_and_daily_notes() {
    let (_d, state, m) = fresh();
    let f = create_folder_ok(&m, "Games", None).await;
    let plain = create_note(&m, json!({ "title": "Old note", "content_md": "Old." })).await;
    let day = create_note(
        &m,
        json!({ "title": "2026-10-01", "content_md": "", "role": "daily" }),
    )
    .await;
    for n in [&plain, &day] {
        let got = add(&m, &f, n).await;
        assert_c1(&got, "role_rule", &[]);
        assert!(
            got["error"]["message"].as_str().unwrap().contains("role"),
            "{got}"
        );
        assert_eq!(membership(&state, &f, n).await, None, "nothing written");
    }
}

// ======================================================================
// AC 19/20: the tools are registered on the served router, and agents
// cannot set `pinned`.
// ======================================================================

/// A `memex serve` subprocess spoken to over newline-delimited JSON-RPC.
struct Server {
    child: Child,
    stdin: ChildStdin,
    lines: Receiver<String>,
}

impl Server {
    fn start(vault: &str) -> Self {
        let mut child = Command::new(env!("CARGO_BIN_EXE_memex"))
            .args(["serve", "--vault", vault])
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .spawn()
            .expect("spawn memex serve");
        let stdin = child.stdin.take().unwrap();
        let stdout = child.stdout.take().unwrap();
        let (tx, lines) = mpsc::channel();
        std::thread::spawn(move || {
            for line in BufReader::new(stdout).lines() {
                let Ok(line) = line else { break };
                if tx.send(line).is_err() {
                    break;
                }
            }
        });
        let mut server = Self {
            child,
            stdin,
            lines,
        };
        let init = server.request(
            1,
            "initialize",
            json!({
                "protocolVersion": "2025-03-26",
                "capabilities": {},
                "clientInfo": { "name": "wi13-test", "version": "0" },
            }),
        );
        assert!(init["result"].is_object(), "initialize failed: {init}");
        server.send(json!({ "jsonrpc": "2.0", "method": "notifications/initialized" }));
        server
    }

    fn send(&mut self, msg: Value) {
        writeln!(self.stdin, "{msg}").expect("write to server");
        self.stdin.flush().unwrap();
    }

    fn request(&mut self, id: i64, method: &str, params: Value) -> Value {
        self.send(json!({ "jsonrpc": "2.0", "id": id, "method": method, "params": params }));
        loop {
            let line = self
                .lines
                .recv_timeout(Duration::from_secs(30))
                .unwrap_or_else(|e| panic!("no response to {method}: {e}"));
            let Ok(v) = serde_json::from_str::<Value>(&line) else {
                continue;
            };
            if v["id"] == json!(id) {
                return v;
            }
        }
    }
}

impl Drop for Server {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

fn required(schema: &Value) -> BTreeSet<String> {
    schema["required"]
        .as_array()
        .map(|a| {
            a.iter()
                .filter_map(|v| v.as_str().map(str::to_string))
                .collect()
        })
        .unwrap_or_default()
}

fn properties(schema: &Value) -> BTreeSet<String> {
    schema["properties"]
        .as_object()
        .map(|o| o.keys().cloned().collect())
        .unwrap_or_default()
}

#[test]
fn mcp_server_registers_the_folder_and_settings_tools() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("vault");
    Vault::create(&path).unwrap();
    let mut server = Server::start(path.to_str().unwrap());
    let resp = server.request(2, "tools/list", json!({}));
    let tools = resp["result"]["tools"]
        .as_array()
        .unwrap_or_else(|| panic!("tools/list failed: {resp}"))
        .clone();
    let schema = |name: &str| -> Value {
        tools
            .iter()
            .find(|t| t["name"] == json!(name))
            .unwrap_or_else(|| panic!("tool {name} is registered"))["inputSchema"]
            .clone()
    };

    for name in ["list_smart_folders", "get_vault_settings"] {
        assert!(required(&schema(name)).is_empty(), "{name} takes no params");
    }
    let s = schema("create_smart_folder");
    assert_eq!(properties(&s), set(&["name", "parent_id"]), "{s}");
    assert_eq!(required(&s), set(&["name"]), "{s}");

    let s = schema("update_smart_folder");
    assert_eq!(
        properties(&s),
        set(&["id", "name", "parent_id", "to_root"]),
        "agents cannot set `pinned`: {s}"
    );
    assert_eq!(required(&s), set(&["id"]), "{s}");

    let s = schema("delete_smart_folder");
    assert_eq!(properties(&s), set(&["id"]), "{s}");
    for name in ["add_to_smart_folder", "remove_from_smart_folder"] {
        let s = schema(name);
        assert_eq!(
            properties(&s),
            set(&["topic_note_id", "smart_folder_id"]),
            "{name}: {s}"
        );
        assert_eq!(
            required(&s),
            set(&["topic_note_id", "smart_folder_id"]),
            "{name}"
        );
    }
}

// ======================================================================
// Implementer additions.
// ======================================================================

#[tokio::test]
async fn mcp_update_with_both_parent_id_and_to_root_is_an_error_and_moves_nothing() {
    let (_d, state, m) = fresh();
    let a = create_folder_ok(&m, "Games", None).await;
    let b = create_folder_ok(&m, "Design", Some(&a)).await;
    let c = create_folder_ok(&m, "Work", None).await;
    let got = update_folder(&m, json!({ "id": b, "parent_id": c, "to_root": true })).await;
    assert_eq!(
        error_obj(&got)["code"],
        json!("update_smart_folder.invalid_params")
    );
    assert_eq!(
        folder_row(&state, &b).await,
        ("Design".to_string(), Some(a), false)
    );
}
