//! WI #401 (C0, rulings D21/D21a): the `compat/*_not_found.json` fixtures for
//! the new hosted routes are exactly what `server::router()`'s not-found
//! handler answers.
//!
//! A hosted server older than the app has no route for `agents`, `echoes`,
//! `words`, `tools` or `embeddings`, so it answers each with the handler's
//! body (`server/mod.rs`, `MemexError::NotFound("no route for this path")`):
//!
//! `404 {"error":{"code":"not_found","message":"not found: no route for this path"}}`
//!
//! The handler's body does not depend on the path, so one probe path that no
//! route serves, now and after the new routes land, proves every fixture. The
//! rows themselves are `dart_only` (the Dart half is
//! `app/test/vault_access/hosted/compat_not_found_fixtures_test.dart`).

#[path = "support/api_fixtures.rs"]
mod api_fixtures;
#[path = "support/server.rs"]
mod server;

use std::fs;

use serde_json::{json, Value};

use api_fixtures::{api_v1_dir, load_rows, materialize_seed};
use server::{client, Reply, TestServer};

const FILES: [&str; 5] = [
    "agents_not_found.json",
    "echoes_not_found.json",
    "words_not_found.json",
    "tools_not_found.json",
    "embeddings_not_found.json",
];

/// A path under the seed vault that no route serves, and none ever will.
const UNROUTED: &str = "/vaults/seed/api/v1/zz-compat-no-such-route";

fn read_fixture(name: &str) -> Value {
    let path = api_v1_dir().join("compat").join(name);
    let text = fs::read_to_string(&path)
        .unwrap_or_else(|e| panic!("compat fixture {} is missing: {e}", path.display()));
    serde_json::from_str(&text).unwrap_or_else(|e| panic!("{name} is not JSON: {e}"))
}

async fn call(srv: &TestServer, method: &str, path: &str) -> Reply {
    let method = reqwest::Method::from_bytes(method.as_bytes()).unwrap();
    let req = client()
        .request(method, srv.url(path))
        .header("authorization", srv.bearer());
    Reply::read(req.send().await.expect("send request")).await
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn every_new_route_compat_fixture_equals_the_body_main_answers_for_an_unrouted_path() {
    let root = tempfile::tempdir().unwrap();
    materialize_seed(root.path());
    let srv = TestServer::start_in(root).await;

    let expected = json!({
        "error": {
            "code": "not_found",
            "message": "not found: no route for this path"
        }
    });
    for method in ["GET", "POST", "DELETE"] {
        let reply = call(&srv, method, UNROUTED).await;
        assert_eq!(reply.status, 404, "{method} {UNROUTED}: {}", reply.body);
        assert_eq!(reply.json(), expected, "{method} {UNROUTED}");
    }
    for name in FILES {
        let fixture = read_fixture(name);
        assert_eq!(fixture, expected, "{name} drifted from main's handler body");
        let reply = call(&srv, "GET", UNROUTED).await;
        assert_eq!(
            (reply.status, reply.json()),
            (404, fixture),
            "{name} is not what main answers"
        );
    }
}

#[test]
fn compat_index_rows_for_the_new_routes_name_the_five_fixture_files_with_status_404() {
    let rows = load_rows(&api_v1_dir().join("compat")).expect("compat/index.json parses");
    let new_rows: Vec<_> = rows
        .iter()
        .filter(|r| r.path != "/api/v1/info" && !r.path.ends_with("/backup"))
        .map(|r| {
            (
                r.method.as_str(),
                r.response.as_str(),
                r.status,
                r.dart_only,
            )
        })
        .collect();
    assert_eq!(
        new_rows,
        vec![
            ("GET", "agents_not_found.json", 404, true),
            ("GET", "echoes_not_found.json", 404, true),
            ("GET", "words_not_found.json", 404, true),
            ("POST", "words_not_found.json", 404, true),
            ("DELETE", "words_not_found.json", 404, true),
            ("GET", "tools_not_found.json", 404, true),
            ("GET", "embeddings_not_found.json", 404, true),
        ]
    );
    for name in FILES {
        assert!(
            rows.iter().any(|r| r.response == name),
            "no compat row serves {name}"
        );
    }
}
