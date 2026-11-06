//! WI #72 (R0b): the vault routes over HTTP (req 9, 10, 11, 13, 14, 15, 17;
//! D8). In-process unless a test needs `server.log*`, which only the built
//! binary writes.
//!
//! - AC 1: `GET /api/v1/vaults`, sorted by lowercased name, rediscovered
//!   on every list.
//! - AC 2: folders that are never served (dot folders, bad names,
//!   incomplete vaults, escaping symlinks, case-only duplicates), and the
//!   log lines they get.
//! - AC 3–6: `POST /api/v1/vaults`: 201, 400 `invalid_vault_name` /
//!   `invalid_argument`, 409 `vault_exists`, concurrent creates.
//! - AC 7–11: `GET /vaults/<name>/api/v1/info`, the `vault_not_found` guard,
//!   traversal, eviction of a vanished vault, schema on open, single open.
//! - AC 12: no `.memex/models` without `--with-embeddings`.
//! - AC 14: a chunked create body over 8 MiB.

#[path = "support/server.rs"]
mod server;

use std::collections::BTreeMap;
use std::net::SocketAddr;
use std::path::Path;
use std::sync::Arc;

use memex_core::schema::APP_SCHEMA_VERSION;
use memex_core::Vault;
use regex::Regex;
use serde_json::{json, Value};
use tokio::sync::Barrier;

use server::{
    assert_wrong_method_is_c1_405, client, encode_segment, free_port, get, make_v4_vault,
    make_vault, post_json, raw_get, raw_request, set_manifest_schema_version, tree_snapshot,
    wait_for_logs, CaseSensitiveDir, Reply, ServeChild, ServeCommand, TestServer, ANY_PORT,
    BODY_LIMIT, TOKEN_ENV,
};

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

async fn list(srv: &TestServer) -> Value {
    let r = get(&srv.url("/api/v1/vaults"), Some(&srv.bearer())).await;
    assert_eq!(r.status, 200, "GET /api/v1/vaults: {}", r.body);
    r.json()
}

fn names_of(list: &Value) -> Vec<String> {
    list["vaults"]
        .as_array()
        .unwrap_or_else(|| panic!("no vaults array: {list}"))
        .iter()
        .map(|v| v["name"].as_str().expect("string name").to_string())
        .collect()
}

async fn listed(srv: &TestServer) -> Vec<String> {
    names_of(&list(srv).await)
}

async fn create(srv: &TestServer, name: &str) -> Reply {
    post_json(
        &srv.url("/api/v1/vaults"),
        &json!({ "name": name }),
        Some(&srv.bearer()),
    )
    .await
}

/// `GET /vaults/<name>/api/v1/info`, with `name` percent-encoded.
async fn info(srv: &TestServer, name: &str) -> Reply {
    raw_get(
        srv,
        "GET",
        &format!("/vaults/{}/api/v1/info", encode_segment(name)),
    )
    .await
}

fn assert_vault_not_found(r: &Reply, what: &str) {
    assert_eq!(r.status, 404, "{what}: {}", r.body);
    assert_eq!(r.c1_code(), "vault_not_found", "{what}");
}

fn is_ulid(s: &str) -> bool {
    s.len() == 26 && ulid::Ulid::from_string(s).is_ok()
}

/// The keys of a JSON object, sorted.
fn keys(v: &Value) -> Vec<String> {
    let mut k: Vec<String> = v
        .as_object()
        .unwrap_or_else(|| panic!("not an object: {v}"))
        .keys()
        .cloned()
        .collect();
    k.sort();
    k
}

/// The entry names directly under `dir`, sorted.
fn dir_names(dir: &Path) -> Vec<String> {
    let mut names: Vec<String> = std::fs::read_dir(dir)
        .unwrap()
        .map(|e| e.unwrap().file_name().to_string_lossy().into_owned())
        .collect();
    names.sort();
    names
}

fn copy_dir(from: &Path, to: &Path) {
    std::fs::create_dir_all(to).unwrap();
    for entry in std::fs::read_dir(from).unwrap() {
        let entry = entry.unwrap();
        let target = to.join(entry.file_name());
        if entry.file_type().unwrap().is_dir() {
            copy_dir(&entry.path(), &target);
        } else {
            std::fs::copy(entry.path(), target).unwrap();
        }
    }
}

/// A POST of `body` to `/api/v1/vaults` with `content_type`, over a bare
/// socket so the bytes are exactly these.
async fn post_raw(srv: &TestServer, content_type: &str, body: &[u8]) -> Reply {
    let head = format!(
        "POST /api/v1/vaults HTTP/1.1\r\nHost: localhost\r\nAuthorization: {}\r\n\
         Content-Type: {content_type}\r\nContent-Length: {}\r\nConnection: close\r\n",
        srv.bearer(),
        body.len()
    );
    raw_request(srv.addr(), &head, body).await
}

/// Sends every request in `bodies` to `POST /api/v1/vaults` at once.
async fn parallel_creates(srv: &TestServer, names: &[String]) -> Vec<Reply> {
    let barrier = Arc::new(Barrier::new(names.len()));
    let url = srv.url("/api/v1/vaults");
    let bearer = srv.bearer();
    let tasks: Vec<_> = names
        .iter()
        .map(|name| {
            let barrier = barrier.clone();
            let url = url.clone();
            let bearer = bearer.clone();
            let body = json!({ "name": name });
            tokio::spawn(async move {
                let http = client();
                let req = http.post(&url).header("authorization", bearer).json(&body);
                barrier.wait().await;
                Reply::read(req.send().await.expect("send POST")).await
            })
        })
        .collect();
    let mut out = Vec::new();
    for t in tasks {
        out.push(t.await.expect("create task"));
    }
    out
}

fn statuses(replies: &[Reply]) -> BTreeMap<u16, usize> {
    let mut m = BTreeMap::new();
    for r in replies {
        *m.entry(r.status).or_insert(0) += 1;
    }
    m
}

// ---------------------------------------------------------------------------
// AC 1: list
// ---------------------------------------------------------------------------

#[tokio::test]
async fn list_returns_every_vault_sorted_by_lowercased_name() {
    let root = tempfile::tempdir().unwrap();
    let mut ids = BTreeMap::new();
    for name in ["gamma", "Zed", "alpha", "_x", "Beta", "9lives", "-dash"] {
        ids.insert(name, make_vault(root.path(), name));
    }
    let srv = TestServer::start_in(root).await;

    // Byte order would put `Beta` and `Zed` before `_x` and `alpha`.
    let order = ["-dash", "9lives", "_x", "alpha", "Beta", "gamma", "Zed"];
    let expected = json!({
        "vaults": order
            .iter()
            .map(|n| json!({ "name": n, "vault_id": ids[n] }))
            .collect::<Vec<_>>(),
    });
    assert_eq!(list(&srv).await, expected);
}

#[tokio::test]
async fn list_of_an_empty_root_is_an_empty_array() {
    let srv = TestServer::start().await;
    assert_eq!(list(&srv).await, json!({ "vaults": [] }));
}

#[tokio::test]
async fn a_vault_copied_into_the_root_while_running_is_listed_and_served() {
    let root = tempfile::tempdir().unwrap();
    let alpha = make_vault(root.path(), "alpha");
    let srv = TestServer::start_in(root).await;
    assert_eq!(
        list(&srv).await,
        json!({ "vaults": [{ "name": "alpha", "vault_id": alpha }] })
    );

    let elsewhere = tempfile::tempdir().unwrap();
    let late = make_vault(elsewhere.path(), "late");
    copy_dir(&elsewhere.path().join("late"), &srv.root().join("late"));

    assert_eq!(
        list(&srv).await,
        json!({ "vaults": [
            { "name": "alpha", "vault_id": alpha },
            { "name": "late", "vault_id": late },
        ] })
    );
    let r = info(&srv, "late").await;
    assert_eq!(r.status, 200, "{}", r.body);
    assert_eq!(r.json()["vault_id"], json!(late));
}

// ---------------------------------------------------------------------------
// AC 2: never served
// ---------------------------------------------------------------------------

#[tokio::test]
async fn dot_folders_bad_names_incomplete_folders_and_escaping_symlinks_are_never_served() {
    let outer = tempfile::tempdir().unwrap();
    let root = tempfile::tempdir_in(outer.path()).unwrap();
    let r = root.path();
    let ok = make_vault(r, "ok");
    let long = "a".repeat(65);
    let bad_names = [".memex", ".incoming", "my vault", long.as_str(), "naïve"];
    for name in bad_names {
        make_vault(r, name);
    }
    make_vault(r, "nodb");
    std::fs::remove_file(r.join("nodb/memex.db")).unwrap();
    make_vault(r, "nomanifest");
    std::fs::remove_file(r.join("nomanifest/manifest.json")).unwrap();
    make_vault(outer.path(), "secret");
    std::os::unix::fs::symlink(outer.path().join("secret"), r.join("escaped")).unwrap();
    std::fs::write(r.join("afile"), b"not a vault").unwrap();

    // Everything but the served `ok` vault.
    let served = r.strip_prefix(outer.path()).unwrap().join("ok");
    let untouched = |dir: &Path| {
        tree_snapshot(dir)
            .into_iter()
            .filter(|(p, _)| !p.starts_with(&served))
            .collect::<Vec<_>>()
    };
    let before = untouched(outer.path());
    let srv = TestServer::start_in(root).await;

    for _ in 0..2 {
        assert_eq!(
            list(&srv).await,
            json!({ "vaults": [{ "name": "ok", "vault_id": ok }] })
        );
    }
    let mut never = bad_names.to_vec();
    never.extend(["nodb", "nomanifest", "escaped", "afile"]);
    for name in never {
        let r = info(&srv, name).await;
        assert_vault_not_found(&r, &format!("info for {name:?}"));
    }
    // Nothing was opened (no -wal/-shm), created or changed: `nodb` still
    // has no memex.db, `nomanifest` no manifest, `secret` is as it was.
    assert_eq!(untouched(outer.path()), before);
}

#[tokio::test]
async fn case_only_duplicate_vault_folders_are_neither_listed_nor_served() {
    let cs = CaseSensitiveDir::new();
    let root = cs.tempdir();
    make_vault(root.path(), "Work");
    make_vault(root.path(), "work");
    let other = make_vault(root.path(), "other");
    let srv = TestServer::start_in(root).await;

    assert_eq!(
        list(&srv).await,
        json!({ "vaults": [{ "name": "other", "vault_id": other }] })
    );
    for name in ["Work", "work", "WORK"] {
        assert_vault_not_found(&info(&srv, name).await, &format!("info for {name}"));
    }
    // The name is still taken: creating it makes no third folder.
    let r = create(&srv, "WORK").await;
    assert_eq!(r.status, 409, "{}", r.body);
    assert_eq!(r.c1_code(), "vault_exists");
    assert_eq!(dir_names(srv.root()), ["Work", "other", "work"]);
    drop(srv);
}

const LOG_TOKEN: &str = "wi72-log-token-8b7a6c5d4e3f2a1b0c9d8e7f";

/// `memex serve --root <root>` on a port the child binds itself (never a
/// probed-then-released one another process could take first).
async fn start_binary(root: &Path) -> (ServeChild, SocketAddr) {
    let mut child = ServeCommand::new(&[
        "--root",
        root.to_str().unwrap(),
        "--listen",
        ANY_PORT,
        "--log-level",
        "info",
    ])
    .env(TOKEN_ENV, LOG_TOKEN)
    .spawn();
    let addr = child.ready().await;
    (child, addr)
}

/// Access-log lines for `path`.
fn access_lines(logs: &str, path: &str) -> usize {
    let needle = format!("path={path} ");
    logs.lines()
        .filter(|l| l.contains("memex::access") && l.contains(&needle))
        .count()
}

#[tokio::test]
async fn case_only_duplicate_vault_folders_log_one_warning_naming_both() {
    let cs = CaseSensitiveDir::new();
    let root = cs.tempdir();
    make_vault(root.path(), "Work");
    make_vault(root.path(), "work");
    make_vault(root.path(), "other");
    let (mut child, addr) = start_binary(root.path()).await;
    let bearer = format!("Bearer {LOG_TOKEN}");

    for _ in 0..3 {
        let r = get(&format!("http://{addr}/api/v1/vaults"), Some(&bearer)).await;
        assert_eq!(r.status, 200, "{}", r.body);
        assert_eq!(names_of(&r.json()), ["other"]);
    }
    // Each access line is written after its handler ran.
    let logs = wait_for_logs(root.path(), |l| access_lines(l, "/api/v1/vaults") >= 3).await;
    let upper = Regex::new(r"\bWork\b").unwrap();
    let lower = Regex::new(r"\bwork\b").unwrap();
    let warnings: Vec<&str> = logs
        .lines()
        .filter(|l| l.contains("WARN") && upper.is_match(l) && lower.is_match(l))
        .collect();
    assert_eq!(warnings.len(), 1, "one warning naming both; logs=\n{logs}");
    child.stop();
}

#[tokio::test]
async fn an_invalid_name_vault_folder_is_logged_once_not_per_request() {
    let root = tempfile::tempdir().unwrap();
    make_vault(root.path(), "my vault");
    make_vault(root.path(), "ok");
    let (mut child, addr) = start_binary(root.path()).await;
    let bearer = format!("Bearer {LOG_TOKEN}");

    for _ in 0..3 {
        let r = get(&format!("http://{addr}/api/v1/vaults"), Some(&bearer)).await;
        assert_eq!(r.status, 200, "{}", r.body);
        assert_eq!(names_of(&r.json()), ["ok"]);
    }
    let logs = wait_for_logs(root.path(), |l| access_lines(l, "/api/v1/vaults") >= 3).await;
    let mentions = logs.lines().filter(|l| l.contains("my vault")).count();
    assert_eq!(mentions, 1, "logged once; logs=\n{logs}");

    // AC 12: a server started without --with-embeddings makes no models dir.
    assert!(!root.path().join(".memex/models").exists());
    assert!(!root.path().join("ok/.memex/models").exists());
    child.stop();
}

// ---------------------------------------------------------------------------
// AC 3: create
// ---------------------------------------------------------------------------

#[tokio::test]
async fn create_returns_201_and_makes_a_vault_that_opens_at_schema_5() {
    assert_eq!(APP_SCHEMA_VERSION, 6);
    let srv = TestServer::start().await;
    let r = create(&srv, "work").await;
    assert_eq!(r.status, 201, "{}", r.body);
    let body = r.json();
    assert_eq!(keys(&body), ["name", "vault_id"]);
    assert_eq!(body["name"], json!("work"));
    let id = body["vault_id"].as_str().unwrap().to_string();
    assert!(is_ulid(&id), "vault_id {id:?} is a ULID");

    let vault = Vault::open(srv.root().join("work")).expect("Vault::open accepts it");
    assert_eq!(vault.manifest().schema_version, APP_SCHEMA_VERSION);
    assert_eq!(vault.manifest().vault_id, id);
    drop(vault);

    assert_eq!(
        list(&srv).await,
        json!({ "vaults": [{ "name": "work", "vault_id": id }] })
    );
    let r = info(&srv, "work").await;
    assert_eq!(r.status, 200, "{}", r.body);
    assert_eq!(r.json()["vault_id"], json!(id));
}

#[tokio::test]
async fn create_accepts_a_64_character_name_and_keeps_its_case() {
    let name = format!("A{}Z", "b".repeat(62));
    assert_eq!(name.len(), 64);
    let srv = TestServer::start().await;
    let r = create(&srv, &name).await;
    assert_eq!(r.status, 201, "{}", r.body);
    assert_eq!(r.json()["name"], json!(name));
    assert_eq!(dir_names(srv.root()), std::slice::from_ref(&name));
    assert_eq!(listed(&srv).await, [name]);
}

// ---------------------------------------------------------------------------
// AC 4: invalid names and bodies
// ---------------------------------------------------------------------------

#[tokio::test]
async fn create_with_an_invalid_name_is_400_invalid_vault_name_and_creates_nothing() {
    let outer = tempfile::tempdir().unwrap();
    let root = tempfile::tempdir_in(outer.path()).unwrap();
    let inside_abs = format!("{}/abs", outer.path().display());
    let long = "a".repeat(65);
    let names: Vec<&str> = vec![
        "",
        long.as_str(),
        "a b",
        "../x",
        "x/y",
        ".hidden",
        "ü",
        ".",
        "..",
        "x\\y",
        "..\\x",
        "a\0b",
        inside_abs.as_str(),
        "work\n",
        " work",
        "work ",
        "tab\tx",
        "x:y",
        "a.b",
        "%2e%2e",
        "\u{212A}elvin", // KELVIN SIGN lowercases to ASCII `k`
        "\u{FF57}ork",   // fullwidth w
        "w\u{00F6}rk",
        "\u{0130}stanbul",
    ];
    let before = tree_snapshot(outer.path());
    let srv = TestServer::start_in(root).await;
    for name in names {
        let r = create(&srv, name).await;
        assert_eq!(r.status, 400, "create {name:?}: {}", r.body);
        assert_eq!(r.c1_code(), "invalid_vault_name", "create {name:?}");
    }
    assert_eq!(
        tree_snapshot(outer.path()),
        before,
        "nothing on disk changed"
    );
    assert_eq!(list(&srv).await, json!({ "vaults": [] }));
}

#[tokio::test]
async fn create_with_a_malformed_body_is_400_invalid_argument_and_creates_nothing() {
    let srv = TestServer::start().await;
    let json_ct = "application/json";
    let cases: Vec<(&str, &[u8])> = vec![
        (json_ct, b"not json"),
        (json_ct, b""),
        (json_ct, b"{}"),
        (json_ct, br#"{"name":5}"#),
        (json_ct, br#"{"name":null}"#),
        (json_ct, br#"{"name":["work"]}"#),
        (json_ct, br#"{"Name":"work"}"#),
        (json_ct, b"[]"),
        (json_ct, br#""work""#),
        (json_ct, br#"{"name":"work""#),
        ("text/plain", br#"{"name":"work"}"#),
    ];
    for (content_type, body) in cases {
        let what = format!("{content_type} {:?}", String::from_utf8_lossy(body));
        let r = post_raw(&srv, content_type, body).await;
        assert_eq!(r.status, 400, "{what}: {}", r.body);
        assert_eq!(r.c1_code(), "invalid_argument", "{what}");
    }
    assert!(dir_names(srv.root()).is_empty(), "nothing created");
    assert_eq!(list(&srv).await, json!({ "vaults": [] }));
}

// ---------------------------------------------------------------------------
// AC 5: taken names
// ---------------------------------------------------------------------------

#[tokio::test]
async fn create_of_a_taken_name_is_409_vault_exists() {
    let root = tempfile::tempdir().unwrap();
    let work = make_vault(root.path(), "work");
    std::fs::create_dir(root.path().join("plain")).unwrap();
    std::fs::write(root.path().join("plain/keep.txt"), b"mine").unwrap();
    std::fs::write(root.path().join("afile"), b"also mine").unwrap();
    let before = tree_snapshot(root.path());
    let srv = TestServer::start_in(root).await;

    for name in ["work", "Work", "WORK", "plain", "PLAIN", "afile"] {
        let r = create(&srv, name).await;
        assert_eq!(r.status, 409, "create {name}: {}", r.body);
        assert_eq!(r.c1_code(), "vault_exists", "create {name}");
    }
    assert_eq!(tree_snapshot(srv.root()), before, "nothing on disk changed");
    assert_eq!(
        list(&srv).await,
        json!({ "vaults": [{ "name": "work", "vault_id": work }] })
    );
}

#[tokio::test]
async fn create_clashing_only_by_case_is_409_on_a_case_sensitive_root() {
    let cs = CaseSensitiveDir::new();
    let root = cs.tempdir();
    make_vault(root.path(), "work");
    std::fs::create_dir(root.path().join("Plain")).unwrap();
    let srv = TestServer::start_in(root).await;

    for name in ["Work", "WORK", "plain"] {
        let r = create(&srv, name).await;
        assert_eq!(r.status, 409, "create {name}: {}", r.body);
        assert_eq!(r.c1_code(), "vault_exists", "create {name}");
    }
    assert_eq!(dir_names(srv.root()), ["Plain", "work"]);
    drop(srv);
}

// ---------------------------------------------------------------------------
// AC 6: concurrent creates
// ---------------------------------------------------------------------------

#[tokio::test(flavor = "multi_thread", worker_threads = 8)]
async fn eight_parallel_creates_of_one_name_yield_one_201_and_seven_409s() {
    let srv = TestServer::start().await;
    let mut made = Vec::new();
    for round in 0..5 {
        let name = format!("race{round}");
        let replies = parallel_creates(&srv, &vec![name.clone(); 8]).await;
        assert_eq!(
            statuses(&replies),
            BTreeMap::from([(201, 1), (409, 7)]),
            "round {round}: {:?}",
            replies.iter().map(|r| &r.body).collect::<Vec<_>>()
        );
        for r in replies.iter().filter(|r| r.status == 409) {
            assert_eq!(r.c1_code(), "vault_exists");
        }
        let id = replies.iter().find(|r| r.status == 201).unwrap().json()["vault_id"].clone();
        let vault = Vault::open(srv.root().join(&name)).expect("the winner is a vault");
        assert_eq!(json!(vault.manifest().vault_id), id);
        made.push(name);
    }
    assert_eq!(listed(&srv).await, made);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn parallel_creates_of_names_differing_only_by_case_yield_one_201() {
    let cs = CaseSensitiveDir::new();
    let root = cs.tempdir();
    let srv = TestServer::start_in(root).await;
    for round in 0..5 {
        let names = vec![format!("Team{round}"), format!("team{round}")];
        let replies = parallel_creates(&srv, &names).await;
        assert_eq!(
            statuses(&replies),
            BTreeMap::from([(201, 1), (409, 1)]),
            "round {round}: {:?}",
            replies.iter().map(|r| &r.body).collect::<Vec<_>>()
        );
    }
    assert_eq!(
        dir_names(srv.root()).len(),
        5,
        "{:?}",
        dir_names(srv.root())
    );
    assert_eq!(listed(&srv).await.len(), 5);
    drop(srv);
}

// ---------------------------------------------------------------------------
// AC 7: info
// ---------------------------------------------------------------------------

#[tokio::test]
async fn vault_info_returns_name_vault_id_and_schema_version() {
    let root = tempfile::tempdir().unwrap();
    let id = make_vault(root.path(), "work");
    let srv = TestServer::start_in(root).await;
    let r = info(&srv, "work").await;
    assert_eq!(r.status, 200, "{}", r.body);
    assert_eq!(
        r.json(),
        json!({ "name": "work", "vault_id": id, "schema_version": APP_SCHEMA_VERSION })
    );
    // A served vault passes the guard: an unknown API path under it is a
    // plain `not_found`, never `vault_not_found`.
    let r = raw_get(&srv, "GET", "/vaults/work/api/v1/no-such-route").await;
    assert_eq!(r.status, 404, "{}", r.body);
    assert_eq!(r.c1_code(), "not_found");
}

#[tokio::test]
async fn vault_info_lookup_is_case_insensitive_and_answers_with_the_folder_name() {
    let root = tempfile::tempdir().unwrap();
    let work = make_vault(root.path(), "work");
    let mixed = make_vault(root.path(), "MiXed");
    let srv = TestServer::start_in(root).await;
    for (asked, folder, id) in [
        ("WORK", "work", &work),
        ("Work", "work", &work),
        ("mixed", "MiXed", &mixed),
        ("MIXED", "MiXed", &mixed),
    ] {
        let r = info(&srv, asked).await;
        assert_eq!(r.status, 200, "info {asked}: {}", r.body);
        assert_eq!(
            r.json(),
            json!({ "name": folder, "vault_id": id, "schema_version": APP_SCHEMA_VERSION }),
            "info {asked}"
        );
    }
}

#[tokio::test]
async fn wrong_methods_on_the_vault_routes_are_c1_405_method_not_allowed() {
    let root = tempfile::tempdir().unwrap();
    let id = make_vault(root.path(), "work");
    let srv = TestServer::start_in(root).await;
    let before = dir_names(srv.root());
    // The nested `/vaults/{name}/api/v1` router holds no routes yet (#81
    // adds them and calls this helper); #80 probes `/vaults/{name}/mcp` in
    // server_mcp.rs.
    assert_wrong_method_is_c1_405(
        &srv,
        &[
            ("/api/v1/vaults", &["GET", "POST"]),
            ("/vaults/work/api/v1/info", &["GET"]),
            ("/vaults/WORK/api/v1/info", &["GET"]),
        ],
    )
    .await;
    // The served methods on the same paths are unaffected, and nothing was
    // created or removed.
    assert_eq!(listed(&srv).await, vec!["work".to_string()]);
    let r = info(&srv, "work").await;
    assert_eq!(r.status, 200, "{}", r.body);
    assert_eq!(r.json()["vault_id"], json!(id));
    assert_eq!(dir_names(srv.root()), before);
}

#[tokio::test]
async fn a_wrong_method_on_an_unknown_vault_is_404_vault_not_found_not_405() {
    // The vault guard answers before routing, so a name that is not served
    // is `vault_not_found` whatever the method.
    let root = tempfile::tempdir().unwrap();
    make_vault(root.path(), "work");
    let srv = TestServer::start_in(root).await;
    for method in ["POST", "PUT", "DELETE", "PATCH", "OPTIONS"] {
        let path = "/vaults/nope/api/v1/info";
        let r = raw_get(&srv, method, path).await;
        assert_vault_not_found(&r, &format!("{method} {path}"));
    }
}

// ---------------------------------------------------------------------------
// AC 8: unknown names and traversal
// ---------------------------------------------------------------------------

#[tokio::test]
async fn unknown_and_traversal_names_are_404_vault_not_found_on_every_vault_path() {
    let outer = tempfile::tempdir().unwrap();
    let root = tempfile::tempdir_in(outer.path()).unwrap();
    make_vault(root.path(), "work");
    make_vault(outer.path(), "secret");
    let abs_secret = std::path::absolute(outer.path().join("secret")).unwrap();
    let root_name = root
        .path()
        .file_name()
        .unwrap()
        .to_string_lossy()
        .into_owned();
    let srv = TestServer::start_in(root).await;
    let before = tree_snapshot(outer.path());

    // Path segments exactly as sent (already encoded where needed).
    let segments = vec![
        "nope".to_string(),
        "secret".to_string(),
        "..".to_string(),
        ".".to_string(),
        "%2E%2E".to_string(),
        "%2e%2e".to_string(),
        "%2E".to_string(),
        "..%2Fsecret".to_string(),
        "%2E%2E%2Fsecret".to_string(),
        "..%5Csecret".to_string(),
        "work%2F..%2F..%2Fsecret".to_string(),
        format!("..%2F{root_name}%2Fwork"),
        "work%2F".to_string(),
        "%2F".to_string(),
        "%00".to_string(),
        "work%00".to_string(),
        encode_segment(&abs_secret.display().to_string()),
    ];
    let suffixes = [
        ("GET", "/api/v1/info"),
        ("GET", "/api/v1/notes"),
        ("GET", "/api/v1/anything/at/all"),
        ("GET", "/mcp"),
        ("POST", "/mcp"),
    ];
    for segment in &segments {
        for (method, suffix) in suffixes {
            let path = format!("/vaults/{segment}{suffix}");
            let r = raw_get(&srv, method, &path).await;
            assert_vault_not_found(&r, &format!("{method} {path}"));
        }
    }
    assert_eq!(
        tree_snapshot(outer.path()),
        before,
        "no file outside the root (or inside it) was opened or created"
    );
}

// ---------------------------------------------------------------------------
// AC 9: vanished vault
// ---------------------------------------------------------------------------

#[tokio::test]
async fn a_deleted_vault_is_404_and_a_recreated_one_is_served_with_its_new_vault_id() {
    let srv = TestServer::start().await;
    let r = create(&srv, "work").await;
    assert_eq!(r.status, 201, "{}", r.body);
    let first = r.json()["vault_id"].as_str().unwrap().to_string();
    let r = info(&srv, "work").await;
    assert_eq!(r.status, 200, "{}", r.body);
    assert_eq!(r.json()["vault_id"], json!(first));

    std::fs::remove_dir_all(srv.root().join("work")).unwrap();
    assert_vault_not_found(&info(&srv, "work").await, "info after delete");
    assert_eq!(list(&srv).await, json!({ "vaults": [] }));

    // Recreated through the API.
    let r = create(&srv, "work").await;
    assert_eq!(r.status, 201, "recreate: {}", r.body);
    let second = r.json()["vault_id"].as_str().unwrap().to_string();
    assert_ne!(second, first);
    let r = info(&srv, "work").await;
    assert_eq!(r.status, 200, "{}", r.body);
    assert_eq!(r.json()["vault_id"], json!(second), "not the old handle");

    // Recreated on disk behind the server's back.
    std::fs::remove_dir_all(srv.root().join("work")).unwrap();
    assert_vault_not_found(&info(&srv, "work").await, "info after second delete");
    let third = make_vault(srv.root(), "work");
    let r = info(&srv, "work").await;
    assert_eq!(r.status, 200, "{}", r.body);
    assert_eq!(r.json()["vault_id"], json!(third), "not the old handle");
}

#[tokio::test]
async fn a_vault_whose_manifest_is_removed_is_404_vault_not_found() {
    let root = tempfile::tempdir().unwrap();
    make_vault(root.path(), "work");
    let srv = TestServer::start_in(root).await;
    assert_eq!(info(&srv, "work").await.status, 200);
    std::fs::remove_file(srv.root().join("work/manifest.json")).unwrap();
    assert_vault_not_found(&info(&srv, "work").await, "info without a manifest");
    assert_eq!(list(&srv).await, json!({ "vaults": [] }));
    assert!(
        !srv.root().join("work/manifest.json").exists(),
        "the manifest is not recreated"
    );
}

// ---------------------------------------------------------------------------
// AC 10: schema on open
// ---------------------------------------------------------------------------

#[tokio::test]
async fn an_older_schema_vault_is_migrated_on_first_use() {
    let root = tempfile::tempdir().unwrap();
    let id = make_v4_vault(root.path(), "old");
    let srv = TestServer::start_in(root).await;
    let r = info(&srv, "old").await;
    assert_eq!(r.status, 200, "{}", r.body);
    assert_eq!(
        r.json(),
        json!({ "name": "old", "vault_id": id, "schema_version": APP_SCHEMA_VERSION })
    );
    let manifest: Value =
        serde_json::from_slice(&std::fs::read(srv.root().join("old/manifest.json")).unwrap())
            .unwrap();
    assert_eq!(manifest["schema_version"], json!(APP_SCHEMA_VERSION));
}

#[tokio::test]
async fn a_newer_schema_vault_is_refused_with_500_internal() {
    let root = tempfile::tempdir().unwrap();
    make_vault(root.path(), "future");
    set_manifest_schema_version(&root.path().join("future"), APP_SCHEMA_VERSION + 1);
    let srv = TestServer::start_in(root).await;
    for attempt in 0..2 {
        let r = info(&srv, "future").await;
        assert_eq!(r.status, 500, "attempt {attempt}: {}", r.body);
        assert_eq!(r.c1_code(), "internal");
        assert_eq!(
            r.json()["error"]["message"],
            json!(format!(
                "schema version unsupported: db={}, app={APP_SCHEMA_VERSION}",
                APP_SCHEMA_VERSION + 1
            ))
        );
    }
}

// ---------------------------------------------------------------------------
// AC 11: single open
// ---------------------------------------------------------------------------

#[tokio::test(flavor = "multi_thread", worker_threads = 8)]
async fn sixteen_concurrent_first_requests_open_the_vault_once() {
    let root = tempfile::tempdir().unwrap();
    // A V4 vault, so the first open has a migration to run.
    let id = make_v4_vault(root.path(), "busy");
    let srv = TestServer::start_in(root).await;
    let barrier = Arc::new(Barrier::new(16));
    let url = srv.url("/vaults/busy/api/v1/info");
    let bearer = srv.bearer();
    let tasks: Vec<_> = (0..16)
        .map(|_| {
            let barrier = barrier.clone();
            let url = url.clone();
            let bearer = bearer.clone();
            tokio::spawn(async move {
                let req = client().get(&url).header("authorization", bearer);
                barrier.wait().await;
                Reply::read(req.send().await.expect("send GET")).await
            })
        })
        .collect();
    for t in tasks {
        let r = t.await.unwrap();
        assert!(!r.body.contains("locked"), "{}", r.body);
        assert_eq!(r.status, 200, "{}", r.body);
        assert_eq!(
            r.json(),
            json!({ "name": "busy", "vault_id": id, "schema_version": APP_SCHEMA_VERSION })
        );
    }
}

// ---------------------------------------------------------------------------
// AC 12: no embedder without --with-embeddings
// ---------------------------------------------------------------------------

#[tokio::test]
async fn a_server_without_embeddings_creates_no_models_dir() {
    let root = tempfile::tempdir().unwrap();
    make_vault(root.path(), "existing");
    let srv = TestServer::start_in(root).await;
    list(&srv).await;
    assert_eq!(create(&srv, "work").await.status, 201);
    assert_eq!(info(&srv, "work").await.status, 200);
    assert_eq!(info(&srv, "existing").await.status, 200);
    for dir in [
        ".memex/models",
        "work/.memex/models",
        "existing/.memex/models",
    ] {
        assert!(!srv.root().join(dir).exists(), "{dir} was created");
    }
}

// ---------------------------------------------------------------------------
// AC 14: chunked body over the limit
// ---------------------------------------------------------------------------

fn chunked(body: &[u8]) -> Vec<u8> {
    let mut out = Vec::new();
    for chunk in body.chunks(64 * 1024) {
        out.extend_from_slice(format!("{:X}\r\n", chunk.len()).as_bytes());
        out.extend_from_slice(chunk);
        out.extend_from_slice(b"\r\n");
    }
    out.extend_from_slice(b"0\r\n\r\n");
    out
}

async fn post_chunked(srv: &TestServer, body: &[u8]) -> Reply {
    let head = format!(
        "POST /api/v1/vaults HTTP/1.1\r\nHost: localhost\r\nAuthorization: {}\r\n\
         Content-Type: application/json\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n",
        srv.bearer()
    );
    raw_request(srv.addr(), &head, &chunked(body)).await
}

#[tokio::test]
async fn a_chunked_create_body_over_8_mib_is_413_and_creates_nothing() {
    let srv = TestServer::start().await;
    // A valid create request, padded past the limit with JSON whitespace.
    let body = format!(r#"{{"name":"big"{}}}"#, " ".repeat(BODY_LIMIT));
    assert!(body.len() > BODY_LIMIT);
    let r = post_chunked(&srv, body.as_bytes()).await;
    assert_eq!(r.status, 413, "{}", r.body);
    assert_eq!(r.c1_code(), "payload_too_large");
    assert!(!srv.root().join("big").exists());
    assert_eq!(list(&srv).await, json!({ "vaults": [] }));
}

#[tokio::test]
async fn a_chunked_create_body_under_the_limit_is_accepted() {
    let srv = TestServer::start().await;
    let body = format!(r#"{{"name":"small"{}}}"#, " ".repeat(200_000));
    let r = post_chunked(&srv, body.as_bytes()).await;
    assert_eq!(r.status, 201, "{}", r.body);
    assert_eq!(r.json()["name"], json!("small"));
    assert_eq!(listed(&srv).await, ["small"]);
}

// ---------------------------------------------------------------------------
// Verify: contracts from the implementer's handoff
// ---------------------------------------------------------------------------

#[tokio::test]
async fn a_percent_encoded_vault_name_is_decoded_before_lookup() {
    let outer = tempfile::tempdir().unwrap();
    let root = tempfile::tempdir_in(outer.path()).unwrap();
    let id = make_vault(root.path(), "work");
    make_vault(outer.path(), "secret");
    let srv = TestServer::start_in(root).await;
    let secret = outer.path().join("secret");
    let before = tree_snapshot(&secret);

    // A valid name, escaped in part or whole and in any case, serves it.
    for segment in ["%77ork", "wo%72k", "%77%6F%72%6B", "%57%4F%52%4B", "W%4fRK"] {
        let r = raw_get(&srv, "GET", &format!("/vaults/{segment}/api/v1/info")).await;
        assert_eq!(r.status, 200, "{segment}: {}", r.body);
        assert_eq!(
            r.json(),
            json!({ "name": "work", "vault_id": id, "schema_version": APP_SCHEMA_VERSION }),
            "{segment}"
        );
        // Past the guard: an unrouted path under it is a plain not_found.
        let r = raw_get(&srv, "GET", &format!("/vaults/{segment}/nope")).await;
        assert_eq!(r.status, 404, "{segment}/nope: {}", r.body);
        assert_eq!(r.c1_code(), "not_found", "{segment}/nope");
    }
    // Lower-case encoded traversal and a malformed escape (kept as written,
    // so not a valid name) never resolve.
    for segment in [
        "%2e%2e",
        "%2e%2e%2fsecret",
        "%2f",
        "work%2f",
        "work%2f..%2f..%2fsecret",
        "%zz",
        "wo%7",
        "work%",
        "%%77ork",
    ] {
        for suffix in ["/api/v1/info", "/mcp"] {
            let path = format!("/vaults/{segment}{suffix}");
            assert_vault_not_found(&raw_get(&srv, "GET", &path).await, &path);
        }
    }
    assert_eq!(
        tree_snapshot(&secret),
        before,
        "the outside vault untouched"
    );
    assert_eq!(
        dir_names(outer.path()).len(),
        2,
        "nothing created beside the root"
    );
}

#[tokio::test]
async fn a_symlinked_vault_folder_inside_the_root_is_not_served_and_logged_once_at_warn() {
    let root = tempfile::tempdir().unwrap();
    let r = root.path();
    make_vault(r, "work");
    std::fs::create_dir(r.join(".incoming")).unwrap();
    make_vault(&r.join(".incoming"), "staged");
    std::os::unix::fs::symlink(r.join("work"), r.join("alias")).unwrap();
    std::os::unix::fs::symlink(r.join(".incoming/staged"), r.join("staged")).unwrap();
    let (mut child, addr) = start_binary(r).await;
    let bearer = format!("Bearer {LOG_TOKEN}");

    for _ in 0..3 {
        let resp = get(&format!("http://{addr}/api/v1/vaults"), Some(&bearer)).await;
        assert_eq!(resp.status, 200, "{}", resp.body);
        assert_eq!(names_of(&resp.json()), ["work"]);
    }
    for name in ["alias", "staged"] {
        let path = format!("/vaults/{name}/api/v1/info");
        let resp = get(&format!("http://{addr}{path}"), Some(&bearer)).await;
        assert_vault_not_found(&resp, &path);
    }
    let logs = wait_for_logs(r, |l| {
        access_lines(l, "/api/v1/vaults") >= 3
            && access_lines(l, "/vaults/alias/api/v1/info") >= 1
            && access_lines(l, "/vaults/staged/api/v1/info") >= 1
    })
    .await;
    for name in ["alias", "staged"] {
        let word = Regex::new(&format!(r"\b{name}\b")).unwrap();
        let lines: Vec<&str> = logs
            .lines()
            .filter(|l| !l.contains("memex::access") && word.is_match(l))
            .collect();
        assert_eq!(lines.len(), 1, "{name} logged once; logs=\n{logs}");
        assert!(lines[0].contains("WARN"), "at WARN: {}", lines[0]);
    }
    child.stop();
}

#[tokio::test]
async fn a_failed_vault_create_removes_its_half_made_folder() {
    let root = tempfile::tempdir().unwrap();
    // The log dir exists already; under this umask the server could not
    // add to a folder it made itself.
    std::fs::create_dir(root.path().join(".memex")).unwrap();
    // Every folder the server makes is r-x for its owner only, so
    // `Vault::create` can't fill `<root>/work` after `create_dir` made it.
    let mut child = ServeCommand::under_umask(
        "0277",
        &[
            "--root",
            root.path().to_str().unwrap(),
            "--listen",
            ANY_PORT,
            "--log-level",
            "info",
        ],
    )
    .env(TOKEN_ENV, LOG_TOKEN)
    .spawn();
    let addr = child.ready().await;
    let bearer = format!("Bearer {LOG_TOKEN}");
    let url = format!("http://{addr}/api/v1/vaults");

    for attempt in 0..2 {
        let resp = post_json(&url, &json!({ "name": "work" }), Some(&bearer)).await;
        assert_eq!(resp.status, 500, "attempt {attempt}: {}", resp.body);
        assert_eq!(resp.c1_code(), "internal", "attempt {attempt}");
        assert!(
            !root.path().join("work").exists(),
            "attempt {attempt}: the half-made folder was removed"
        );
    }
    let resp = get(&url, Some(&bearer)).await;
    assert_eq!(resp.json(), json!({ "vaults": [] }));
    child.stop();
}

#[test]
fn with_embeddings_startup_fails_before_binding_when_the_model_cannot_load() {
    let root = tempfile::tempdir().unwrap();
    let listen = format!("127.0.0.1:{}", free_port());
    // Nothing listens there: the model download is refused at once, with
    // no network needed.
    let hub = format!("http://127.0.0.1:{}", free_port());
    let done = ServeCommand::new(&[
        "--root",
        root.path().to_str().unwrap(),
        "--listen",
        &listen,
        "--with-embeddings",
    ])
    .env(TOKEN_ENV, LOG_TOKEN)
    .env("HF_ENDPOINT", &hub)
    .env_remove("HF_HOME")
    .run_within(server::WAIT);
    assert_eq!(done.code, Some(1), "{}", done.describe());
    // One C1 error line naming the embedder. (The run's "load the embedding
    // model" context is dropped by `cli::error_json`, which reports the
    // MemexError in the chain.)
    let lines = done.stderr_lines();
    assert_eq!(lines.len(), 1, "{}", done.describe());
    let err: Value = serde_json::from_str(lines[0]).expect("C1 JSON on stderr");
    assert_eq!(
        err["error"]["code"],
        json!("internal"),
        "{}",
        done.describe()
    );
    let message = err["error"]["message"].as_str().unwrap_or_default();
    assert!(message.contains("embedder"), "{}", done.describe());
    assert!(
        !done.stderr.contains("listening"),
        "failed before binding: {}",
        done.describe()
    );
    assert!(
        std::net::TcpListener::bind(&listen).is_ok(),
        "{listen} was left free"
    );
}
