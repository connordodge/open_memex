//! WI #72 (R0b), AC 15: the `server/` and `errors/` wire-contract rows
//! (D10; lead ruling: this WI owns and runs them). #74's runner sends each
//! row to the in-process server over a fresh copy of the frozen seed vault
//! and compares the normalized response bytes; `MEMEX_BLESS=1` rewrites
//! mismatching rows.
//!
//! The executor speaks raw HTTP/1.1 so a row's headers go out exactly as
//! written (a row may carry its own `Authorization` or `Content-Length`).
//! Without an `Authorization` header a row gets the server's token.

#[path = "support/api_fixtures.rs"]
mod api_fixtures;
#[path = "support/server.rs"]
mod server;

use std::collections::BTreeSet;
use std::path::Path;

use serde_json::Value;

use api_fixtures::{
    api_v1_dir, bless_requested, load_rows, materialize_seed, run_rows, seed_vault_id,
    FixtureRequest, FixtureResponse, SEED_VAULT_NAME,
};
use server::{raw_request, TestServer};

async fn exec(srv: &TestServer, req: &FixtureRequest) -> FixtureResponse {
    let has = |name: &str| req.headers.keys().any(|k| k.eq_ignore_ascii_case(name));
    let mut head = format!(
        "{} {} HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n",
        req.method, req.path
    );
    if !has("authorization") {
        head.push_str(&format!("Authorization: {}\r\n", srv.bearer()));
    }
    for (k, v) in &req.headers {
        head.push_str(&format!("{k}: {v}\r\n"));
    }
    let body = req.body.clone().unwrap_or_default();
    if req.body.is_some() && !has("content-length") {
        head.push_str(&format!("Content-Length: {}\r\n", body.len()));
    }
    let reply = raw_request(srv.addr(), &head, &body).await;
    FixtureResponse {
        status: reply.status,
        body: reply.body.into_bytes(),
    }
}

/// Runs every Rust row of `api_v1/<domain>/` against a fresh in-process
/// server over the seed vault.
fn run_domain(domain: &str) {
    let rt = tokio::runtime::Builder::new_multi_thread()
        .worker_threads(2)
        .enable_all()
        .build()
        .expect("runtime");
    let root = tempfile::tempdir().unwrap();
    materialize_seed(root.path());
    let srv = rt.block_on(TestServer::start_in(root));
    let result = run_rows(&api_v1_dir().join(domain), bless_requested(), |req| {
        rt.block_on(exec(&srv, req))
    });
    drop(srv);
    if let Err(e) = result {
        panic!("{e}");
    }
}

fn response_json(dir: &Path, file: &str) -> Value {
    let path = dir.join(file);
    serde_json::from_slice(&std::fs::read(&path).unwrap_or_else(|e| {
        panic!("read {}: {e}", path.display());
    }))
    .unwrap_or_else(|e| panic!("{} is not JSON: {e}", path.display()))
}

/// WI #415: the vault info fixtures are reblessed at schema V7; every other
/// domain fixture stays byte-identical.
#[test]
fn vault_info_fixtures_carry_schema_version_7() {
    let dir = api_v1_dir().join("server");
    for file in ["vault_info.json", "vault_info_created.json"] {
        assert_eq!(
            response_json(&dir, file)["schema_version"],
            Value::from(7),
            "{file}"
        );
    }
}

#[test]
fn server_fixture_rows_cover_info_and_the_vault_routes_and_match_the_server() {
    let dir = api_v1_dir().join("server");
    let rows = load_rows(&dir).expect("server/index.json parses");
    let seen: BTreeSet<(String, String, u16)> = rows
        .iter()
        .filter(|r| !r.dart_only)
        .map(|r| (r.method.clone(), r.path.clone(), r.status))
        .collect();
    let seed_info = format!("/vaults/{SEED_VAULT_NAME}/api/v1/info");
    for want in [
        ("GET", "/api/v1/info", 200),
        ("GET", "/api/v1/vaults", 200),
        ("POST", "/api/v1/vaults", 201),
        ("GET", seed_info.as_str(), 200),
    ] {
        let want = (want.0.to_string(), want.1.to_string(), want.2);
        assert!(seen.contains(&want), "server/ has a Rust row {want:?}");
    }
    let create = rows
        .iter()
        .find(|r| r.method == "POST" && r.status == 201)
        .unwrap();
    assert_eq!(
        response_json(&dir, &create.response)["vault_id"],
        Value::from("<id:1>"),
        "the minted vault_id is stored normalized"
    );
    let list = rows
        .iter()
        .find(|r| r.path == "/api/v1/vaults" && r.method == "GET")
        .unwrap();
    assert!(
        response_json(&dir, &list.response)["vaults"]
            .as_array()
            .unwrap()
            .iter()
            .any(|v| v["vault_id"] == seed_vault_id()),
        "the list row holds the frozen seed vault"
    );

    run_domain("server");
}

#[test]
fn errors_fixture_rows_cover_every_vault_server_error_body_and_match_the_server() {
    let dir = api_v1_dir().join("errors");
    let rows = load_rows(&dir).expect("errors/index.json parses");
    let seen: BTreeSet<(u16, String)> = rows
        .iter()
        .filter(|r| !r.dart_only)
        .map(|r| {
            let code = response_json(&dir, &r.response)["error"]["code"]
                .as_str()
                .unwrap_or_else(|| panic!("{} is a C1 body", r.response))
                .to_string();
            (r.status, code)
        })
        .collect();
    for (status, code) in [
        (400, "invalid_vault_name"),
        (400, "invalid_argument"),
        (401, "unauthorized"),
        (404, "vault_not_found"),
        (404, "not_found"),
        (409, "vault_exists"),
        (413, "payload_too_large"),
    ] {
        assert!(
            seen.contains(&(status, code.to_string())),
            "errors/ has a Rust row for {status} {code}"
        );
    }

    run_domain("errors");
}
